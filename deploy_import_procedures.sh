#!/usr/bin/env bash
# =====================================================================
#  deploy_import_procedures.sh  (v2 - sans unzip sur l'hote)
#  Import en masse des procedures/annexes/fiches techniques dans la base.
#
#  - Lit PROCEDURES_PLATEFORME.zip (depose dans /opt/registre-gmp).
#  - Sauvegarde la base AVANT (registre.db.<horodatage>.bak sur l'hote).
#  - Copie le zip DANS le conteneur ; l'import (Python du conteneur)
#    extrait lui-meme le zip (reparation des noms accentues) puis importe.
#  - IDEMPOTENT : saute les codes deja presents, ne supprime jamais rien.
#  - Aucun rebuild : les procedures apparaissent immediatement.
#  - Ne touche pas .env. Touche la base UNIQUEMENT en INSERT, apres backup.
#  - N'a besoin d'AUCUN outil sur l'hote a part docker (pas d'unzip/python).
# =====================================================================
set -euo pipefail

APPDIR="${APPDIR:-/opt/registre-gmp}"
CONTAINER="${CONTAINER:-registre-deviations}"
ZIP="${ZIP:-PROCEDURES_PLATEFORME.zip}"
cd "$APPDIR"

[ -f "$ZIP" ] || { echo "ERREUR : $ZIP introuvable dans $APPDIR." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERREUR : docker introuvable." >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "ERREUR : conteneur $CONTAINER non demarre." >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# importeur (s'execute DANS le conteneur, en tant qu'appuser)
cat > "$TMP/_import_proc.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, csv, secrets, sqlite3, datetime, shutil, unicodedata, mimetypes, zipfile
DATA = os.environ.get("DATA_DIR", "/app/data")
DB   = os.path.join(DATA, "registre.db")
PROC = os.path.join(DATA, "procedures")
IMP  = os.path.join(DATA, "_import")
ZIP  = os.environ.get("IMPORT_ZIP", os.path.join(DATA, "_import.zip"))
os.makedirs(PROC, exist_ok=True)
MIME = {".pdf":"application/pdf", ".doc":"application/msword",
        ".docx":"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xls":"application/vnd.ms-excel",
        ".xlsx":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
def norm(s): return unicodedata.normalize("NFC", s)
def fix_name(info):
    name = info.filename
    if not (info.flag_bits & 0x800):
        try: name = name.encode("cp437").decode("utf-8")
        except Exception: pass
    return name
if os.path.exists(ZIP):
    shutil.rmtree(IMP, ignore_errors=True)
    os.makedirs(IMP, exist_ok=True)
    with zipfile.ZipFile(ZIP) as z:
        for info in z.infolist():
            name = fix_name(info)
            target = os.path.join(IMP, name)
            if info.is_dir() or name.endswith("/"):
                os.makedirs(target, exist_ok=True); continue
            os.makedirs(os.path.dirname(target) or IMP, exist_ok=True)
            with z.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
man = os.path.join(IMP, "_manifest.csv")
if not os.path.exists(man):
    print("ERREUR: _manifest.csv introuvable dans", IMP); sys.exit(2)
index = {}
for root, _, files in os.walk(IMP):
    for fn in files:
        if fn == "_manifest.csv": continue
        p = os.path.join(root, fn)
        index[norm(fn)] = p
        try:
            rep = fn.encode("cp437").decode("utf-8")
            index.setdefault(norm(rep), p)
        except Exception: pass
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
cols = {r["name"] for r in con.execute("PRAGMA table_info(procedures)")}
have_meta = "redacteur" in cols
existing = {r["code"] for r in con.execute("SELECT code FROM procedures")}
now = datetime.datetime.now().isoformat(timespec="seconds")
added = skipped = missing = 0
with open(man, encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        code = (row["code"] or "").strip()
        title = (row["intitule"] or "").strip()
        cat = (row["categorie"] or "").strip()
        ver = (row["version"] or "").strip().lstrip("vV")
        fichier = (row["fichier"] or "").strip()
        if not code or not title or not fichier:
            continue
        if code in existing:
            skipped += 1; print("  = deja present, ignore :", code); continue
        src = index.get(norm(fichier))
        if not src:
            missing += 1; print("  ! FICHIER INTROUVABLE :", fichier, "(", code, ")"); continue
        ext = os.path.splitext(src)[1].lower()
        stored = secrets.token_hex(8) + (ext if ext else "")
        shutil.copy2(src, os.path.join(PROC, stored))
        size = os.path.getsize(os.path.join(PROC, stored))
        mime = MIME.get(ext) or mimetypes.guess_type(src)[0] or ""
        c = ["code","title","category","version","filename","orig_name","mime","size","active","uploaded_at","uploaded_by"]
        v = [code, title, cat, ver, stored, fichier, mime, size, 1, now, "Import initial"]
        if have_meta:
            c += ["redacteur","verificateur","approbateur","date_application"]
            v += ["S. Bidault","C. Verdon","S. Rabussier",""]
        con.execute("INSERT INTO procedures(%s) VALUES(%s)" % (",".join(c), ",".join("?"*len(v))), v)
        existing.add(code); added += 1
        print("  + ajoute :", code, "v"+ver, "-", title[:40])
con.commit(); con.close()
print("\nResultat : %d ajoutees, %d ignorees (deja presentes), %d introuvables." % (added, skipped, missing))
if missing:
    sys.exit(3)
PYEOF
chmod 644 "$TMP/_import_proc.py"

echo "=== Sauvegarde de la base (avant import) ==="
docker cp "$CONTAINER:/app/data/registre.db" "$APPDIR/registre.db.$STAMP.bak"
echo "  -> $APPDIR/registre.db.$STAMP.bak ($(wc -c < "$APPDIR/registre.db.$STAMP.bak") octets)"

echo "=== Copie du zip + importeur dans le conteneur ==="
docker exec "$CONTAINER" rm -rf /app/data/_import /app/data/_import.zip /app/data/_import_proc.py 2>/dev/null || true
docker cp "$ZIP" "$CONTAINER:/app/data/_import.zip"
docker cp "$TMP/_import_proc.py" "$CONTAINER:/app/data/_import_proc.py"

echo "=== Import en base (extraction interne + insert idempotent) ==="
set +e
docker exec "$CONTAINER" python3 /app/data/_import_proc.py
rc=$?
set -e

echo "=== Nettoyage ==="
docker exec "$CONTAINER" rm -rf /app/data/_import /app/data/_import.zip /app/data/_import_proc.py || true

echo
if [ "$rc" -eq 3 ]; then
  echo "ATTENTION : des fichiers du manifeste sont introuvables (voir recap). Le reste a ete importe."
elif [ "$rc" -ne 0 ]; then
  echo "ATTENTION : l'import a renvoye le code $rc. Verifie le recap ci-dessus." >&2
fi
echo "=== Termine ==="
echo "Aucun redemarrage necessaire : les procedures sont visibles immediatement (Procedures > Gerer, et onglet Manuel qualite)."
echo "Rollback eventuel :"
echo "  docker cp \"$APPDIR/registre.db.$STAMP.bak\" $CONTAINER:/app/data/registre.db && docker restart $CONTAINER"
