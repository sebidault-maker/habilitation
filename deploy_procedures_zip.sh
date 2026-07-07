#!/usr/bin/env bash
# =============================================================================
#  deploy_procedures_zip.sh
#  Plateforme GMP Scientia Natura — ajoute le telechargement groupe des
#  procedures en un seul fichier ZIP (corrige le blocage navigateur
#  "telechargements multiples" rencontre par l'auditeur).
#
#  - Route serveur : GET /api/procedures/download-all.zip  (@require operator)
#  - Bouton "Tout telecharger (ZIP)" en haut de la liste des procedures.
#
#  Sûr et relançable : sauvegarde .bak horodatee, patch idempotent,
#  controle de compilation d'app.py avec restauration automatique,
#  puis reconstruction Docker. Ne touche a AUCUNE base de donnees.
# =============================================================================
set -euo pipefail

cd /opt/registre-gmp

TS="$(date +%Y%m%d-%H%M%S)"
echo "== Deploiement ZIP procedures ($TS) =="

# --- 0. Fichiers presents ? ---------------------------------------------------
for f in app.py index.html; do
  [ -f "$f" ] || { echo "ERREUR : $f introuvable dans $(pwd)"; exit 1; }
done

# --- 1. Sauvegarde horodatee --------------------------------------------------
cp -p app.py     "app.py.$TS.bak"
cp -p index.html "index.html.$TS.bak"
echo "✓ Sauvegardes : app.py.$TS.bak / index.html.$TS.bak"

# --- 2. Patch via Python (fiable pour l'insertion multi-lignes) --------------
python3 - "$TS" <<'PYEOF'
import io, sys

TS = sys.argv[1]

# ---------- app.py ----------
with io.open("app.py", encoding="utf-8") as fh:
    app = fh.read()

APP_ANCHOR = '@app.post("/api/procedures")'
APP_ROUTE = '''@app.get("/api/procedures/download-all.zip")
@require("operator")
def proc_download_all():
    """Archive ZIP de toutes les procedures actives (un seul telechargement)."""
    con = db()
    rows = con.execute(
        "SELECT * FROM procedures WHERE active=1 ORDER BY category, code").fetchall()
    con.close()
    proc_root = os.path.realpath(PROC_DIR)
    mem = io.BytesIO()
    used = set()
    with zipfile.ZipFile(mem, "w", zipfile.ZIP_DEFLATED) as z:
        for r in rows:
            path = os.path.realpath(os.path.join(PROC_DIR, r["filename"]))
            if not path.startswith(proc_root + os.sep) or not os.path.exists(path):
                continue
            arc = ("%s - %s" % (r["code"] or "", r["orig_name"] or "procedure")).strip()
            arc = arc.replace("/", "-").replace("\\\\", "-")
            base, n = arc, 2
            while arc.lower() in used:
                arc = "%s (%d)" % (base, n); n += 1
            used.add(arc.lower())
            z.write(path, arcname=arc)
    mem.seek(0)
    stamp = now_iso()[:10]
    return send_file(mem, mimetype="application/zip", as_attachment=True,
                     download_name="procedures-scientianatura-%s.zip" % stamp)


'''

if "download-all.zip" in app:
    print("• app.py : deja patche, on saute.")
else:
    if APP_ANCHOR not in app:
        sys.exit("ERREUR : ancre app.py introuvable (%r)." % APP_ANCHOR)
    app = app.replace(APP_ANCHOR, APP_ROUTE + APP_ANCHOR, 1)
    with io.open("app.py", "w", encoding="utf-8") as fh:
        fh.write(app)
    print("✓ app.py : route /api/procedures/download-all.zip ajoutee.")

# ---------- index.html ----------
with io.open("index.html", encoding="utf-8") as fh:
    idx = fh.read()

IDX_ANCHOR = "let html = '<div class=\"card\" style=\"background:var(--cream)\">'"
IDX_NEW = ("let html = '<div class=\"toolbar\"><a class=\"btn btn-ghost btn-sm\" "
           "href=\"/api/procedures/download-all.zip\" download>\u2913 Tout t\u00e9l\u00e9charger (ZIP)</a></div>'\n"
           "    + '<div class=\"card\" style=\"background:var(--cream)\">'")

if "Tout t\u00e9l\u00e9charger (ZIP)" in idx:
    print("• index.html : deja patche, on saute.")
else:
    if IDX_ANCHOR not in idx:
        sys.exit("ERREUR : ancre index.html introuvable.")
    idx = idx.replace(IDX_ANCHOR, IDX_NEW, 1)
    with io.open("index.html", "w", encoding="utf-8") as fh:
        fh.write(idx)
    print("✓ index.html : bouton 'Tout telecharger (ZIP)' ajoute.")
PYEOF

# --- 3. Controle de compilation d'app.py (restauration auto si KO) -----------
if python3 -c "import ast,io; ast.parse(io.open('app.py',encoding='utf-8').read())"; then
    echo "✓ app.py OK."
else
    echo "✗ app.py NE COMPILE PAS — restauration."
    cp -p "app.py.$TS.bak" app.py
    cp -p "index.html.$TS.bak" index.html
    echo "Restauration effectuee. Aucun deploiement lance."
    exit 1
fi

# --- 4. Reconstruction du conteneur ------------------------------------------
echo "== Rebuild Docker =="
docker compose up -d --build

echo
echo "TERMINE. Verifier : ouvrir le manuel qualite > Procedures,"
echo "le bouton « Tout telecharger (ZIP) » doit apparaitre en haut de liste."
echo "(Si l'interface ne bouge pas : Ctrl+Maj+R pour vider le cache.)"
