#!/usr/bin/env bash
# =====================================================================
#  deploy_replace_files.sh
#  Remplace le FICHIER (et la version) de procedures EXISTANTES, par code,
#  d'apres REMPLACEMENTS.zip (+ _remplace.csv). Ne cree aucune entree.
#  Usage prevu : passer ACHA01 en .docx (aperçu) et caler QUAL02/03/04 (v1.1)
#  + PROD05 (v2.1) sur la derniere version.
#
#  - Sauvegarde la base AVANT. Copie/extrait dans le conteneur (Python interne).
#  - Met a jour filename/orig_name/mime/size/version ; supprime l'ancien fichier.
#  - Un changement de version declenche le "a relire" cote utilisateurs.
#  - Aucun rebuild. Ne touche pas .env. Idempotent (re-jouable sans risque).
# =====================================================================
set -euo pipefail
APPDIR="${APPDIR:-/opt/registre-gmp}"
CONTAINER="${CONTAINER:-registre-deviations}"
ZIP="${ZIP:-REMPLACEMENTS.zip}"
cd "$APPDIR"
[ -f "$ZIP" ] || { echo "ERREUR : $ZIP introuvable dans $APPDIR." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERREUR : docker introuvable." >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "ERREUR : conteneur $CONTAINER non demarre." >&2; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/_replace.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, csv, secrets, sqlite3, shutil, unicodedata, mimetypes, zipfile
DATA = os.environ.get("DATA_DIR", "/app/data")
DB   = os.path.join(DATA, "registre.db")
PROC = os.path.join(DATA, "procedures")
IMP  = os.path.join(DATA, "_rempl")
ZIP  = os.environ.get("REMPL_ZIP", os.path.join(DATA, "_rempl.zip"))
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
    shutil.rmtree(IMP, ignore_errors=True); os.makedirs(IMP, exist_ok=True)
    with zipfile.ZipFile(ZIP) as z:
        for info in z.infolist():
            name = fix_name(info); target = os.path.join(IMP, name)
            if info.is_dir() or name.endswith("/"): os.makedirs(target, exist_ok=True); continue
            os.makedirs(os.path.dirname(target) or IMP, exist_ok=True)
            with z.open(info) as s, open(target, "wb") as o: shutil.copyfileobj(s, o)
man = os.path.join(IMP, "_remplace.csv")
if not os.path.exists(man):
    print("ERREUR: _remplace.csv introuvable dans", IMP); sys.exit(2)
index = {}
for root,_,files in os.walk(IMP):
    for fn in files:
        if fn == "_remplace.csv": continue
        index[norm(fn)] = os.path.join(root, fn)
        try: index.setdefault(norm(fn.encode("cp437").decode("utf-8")), os.path.join(root, fn))
        except Exception: pass
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
done = missing = notfound = 0
with open(man, encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        code = (row["code"] or "").strip()
        fichier = (row["fichier"] or "").strip()
        version = (row.get("version") or "").strip().lstrip("vV")
        if not code or not fichier: continue
        src = index.get(norm(fichier))
        if not src:
            missing += 1; print("  ! fichier de remplacement introuvable :", fichier); continue
        rows = con.execute("SELECT id, filename, version FROM procedures WHERE code=?", (code,)).fetchall()
        if not rows:
            notfound += 1; print("  ? code absent de la base, saute :", code); continue
        ext = os.path.splitext(src)[1].lower()
        for r in rows:
            stored = secrets.token_hex(8) + (ext if ext else "")
            shutil.copy2(src, os.path.join(PROC, stored))
            size = os.path.getsize(os.path.join(PROC, stored))
            mime = MIME.get(ext) or mimetypes.guess_type(src)[0] or ""
            newver = version if version else (r["version"] or "")
            con.execute("UPDATE procedures SET filename=?, orig_name=?, mime=?, size=?, version=? WHERE id=?",
                        (stored, fichier, mime, size, newver, r["id"]))
            old = r["filename"]
            if old and old != stored:
                try: os.remove(os.path.join(PROC, old))
                except OSError: pass
            vchg = (r["version"] or "") != newver
            print("  + remplace :", code, "->", fichier, "(v%s%s)" % (newver, ", version changee -> a relire" if vchg else ""))
            done += 1
con.commit(); con.close()
print("\nResultat : %d remplacement(s), %d code(s) absent(s), %d fichier(s) manquant(s)." % (done, notfound, missing))
PYEOF
chmod 644 "$TMP/_replace.py"

echo "=== Sauvegarde de la base (avant) ==="
docker cp "$CONTAINER:/app/data/registre.db" "$APPDIR/registre.db.$STAMP.bak"
echo "  -> $APPDIR/registre.db.$STAMP.bak"
echo "=== Copie zip + replacer dans le conteneur ==="
docker exec "$CONTAINER" rm -rf /app/data/_rempl /app/data/_rempl.zip /app/data/_replace.py 2>/dev/null || true
docker cp "$ZIP" "$CONTAINER:/app/data/_rempl.zip"
docker cp "$TMP/_replace.py" "$CONTAINER:/app/data/_replace.py"
echo "=== Remplacement ==="
set +e
docker exec "$CONTAINER" python3 /app/data/_replace.py
rc=$?
set -e
echo "=== Nettoyage ==="
docker exec "$CONTAINER" rm -rf /app/data/_rempl /app/data/_rempl.zip /app/data/_replace.py || true
echo
[ "$rc" -ne 0 ] && echo "ATTENTION : code retour $rc (voir recap)." >&2
echo "=== Termine ==="
echo "Aucun redemarrage. Rafraichis (Ctrl+Maj+R). ACHA01 s'ouvrira en apercu ; QUAL02/03/04=v1.1, PROD05=v2.1."
echo "Rollback : docker cp \"$APPDIR/registre.db.$STAMP.bak\" $CONTAINER:/app/data/registre.db && docker restart $CONTAINER"
