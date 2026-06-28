#!/usr/bin/env bash
# =====================================================================
# deploy_role_auditeur.sh  —  Laboratoires Scientia Natura (GMP)
# Ajoute le profil « auditeur » (lecture seule) aux registres CAPA et
# auto-inspections, en miroir de cc.py / nc.py / eval.py.
#
# Sûr & relançable :
#   - sauvegarde horodatée de chaque fichier touché (*.AAAAMMJJ-HHMMSS.bak)
#   - vérification que chaque fichier compile ; restauration auto si échec
#   - idempotent : un 2e passage détecte « déjà patché » et ne refait rien
#   - reconstruit ensuite le conteneur (docker compose up -d --build)
#
# NE TOUCHE NI .env NI *.db. Aucun secret n'est écrit par ce script.
# =====================================================================
set -euo pipefail
cd /opt/registre-gmp

echo "== Déploiement : profil auditeur lecture seule (capa.py + inspection.py) =="

for f in capa.py inspection.py docker-compose.yml; do
  [ -f "$f" ] || { echo "ERREUR : $f introuvable dans $(pwd)." >&2; exit 1; }
done

# ── Patch Python (sauvegarde + compile-check + restauration intégrés) ──
python3 - <<'PYEOF'
import os, sys, shutil, datetime, py_compile
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

def apply_repls(path, repls, marker="AUDITEUR_PASSWORD"):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if marker in src:
        print("  %-16s : déjà patché — ignoré." % path); return False
    for old, new in repls:
        n = src.count(old)
        if n != 1:
            print("  ERREUR %s : motif présent %d fois (attendu 1) :\n    %r"
                  % (path, n, old[:70])); sys.exit(2)
        src = src.replace(old, new, 1)
    bak = "%s.%s.bak" % (path, STAMP)
    shutil.copy2(path, bak)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    try:
        py_compile.compile(path, doraise=True)
    except py_compile.PyCompileError as e:
        shutil.copy2(bak, path)
        print("  ERREUR de compilation sur %s — restauré depuis %s.\n%s"
              % (path, os.path.basename(bak), e)); sys.exit(3)
    print("  %-16s : patché OK (sauvegarde %s)" % (path, os.path.basename(bak)))
    return True

CAPA = [
 ('CAPA_PW = os.environ.get("CAPA_PASSWORD", "")\n',
  'CAPA_PW = os.environ.get("CAPA_PASSWORD", "")\n'
  'AUDITEUR = os.environ.get("AUDITEUR_PASSWORD", "")  # lecture seule (profil auditeur)\n'),
 ('''def require_qualite(fn):
    @wraps(fn)
    def w(*a, **k):
        if not CAPA_PW:
            return jsonify({"error": "CAPA_PASSWORD n'est pas défini sur le serveur."}), 503
        if request.headers.get("X-Capa-Password", "") != CAPA_PW:
            return jsonify({"error": "Accès réservé à la Qualité et à l'admin."}), 401
        return fn(*a, **k)
    return w
''',
  '''def _role():
    h = request.headers.get("X-Capa-Password", "")
    if CAPA_PW and h == CAPA_PW:
        return "qualite"
    if AUDITEUR and h == AUDITEUR:
        return "auditeur"
    return None


def require_qualite(fn):
    @wraps(fn)
    def w(*a, **k):
        if not CAPA_PW:
            return jsonify({"error": "CAPA_PASSWORD n'est pas défini sur le serveur."}), 503
        if _role() is None:
            return jsonify({"error": "Accès réservé à la Qualité, à l'admin et aux auditeurs."}), 401
        return fn(*a, **k)
    return w


def require_write(fn):
    @wraps(fn)
    def w(*a, **k):
        if _role() != "qualite":
            return jsonify({"error": "Profil auditeur : consultation seule, modification non autorisée."}), 403
        return fn(*a, **k)
    return w
'''),
 ('@bp.route("/api/capa/check", methods=["POST"])\n@require_qualite\ndef check():\n    return jsonify({"ok": True})\n',
  '@bp.route("/api/capa/check", methods=["POST"])\n@require_qualite\ndef check():\n    return jsonify({"ok": True, "role": _role()})\n'),
 ('@require_qualite\ndef creer():\n',     '@require_qualite\n@require_write\ndef creer():\n'),
 ('@require_qualite\ndef modifier(cid):\n', '@require_qualite\n@require_write\ndef modifier(cid):\n'),
 ('@require_qualite\ndef suivi(cid):\n',  '@require_qualite\n@require_write\ndef suivi(cid):\n'),
 ('@require_qualite\ndef cloturer(cid):\n', '@require_qualite\n@require_write\ndef cloturer(cid):\n'),
 ('@require_qualite\ndef annuler(cid):\n', '@require_qualite\n@require_write\ndef annuler(cid):\n'),
]

INSP = [
 ('INSP_PW = os.environ.get("INSPECTION_PASSWORD", "") or os.environ.get("CAPA_PASSWORD", "")\n',
  'INSP_PW = os.environ.get("INSPECTION_PASSWORD", "") or os.environ.get("CAPA_PASSWORD", "")\n'
  'AUDITEUR = os.environ.get("AUDITEUR_PASSWORD", "")  # lecture seule (profil auditeur)\n'),
 ('''def require_qualite(fn):
    @wraps(fn)
    def w(*a, **k):
        if not INSP_PW:
            return jsonify({"error": "INSPECTION_PASSWORD (ou CAPA_PASSWORD) non défini sur le serveur."}), 503
        if request.headers.get("X-Inspection-Password", "") != INSP_PW:
            return jsonify({"error": "Accès réservé à la Qualité et à l'admin."}), 401
        return fn(*a, **k)
    return w
''',
  '''def _role():
    h = request.headers.get("X-Inspection-Password", "")
    if INSP_PW and h == INSP_PW:
        return "qualite"
    if AUDITEUR and h == AUDITEUR:
        return "auditeur"
    return None


def require_qualite(fn):
    @wraps(fn)
    def w(*a, **k):
        if not INSP_PW:
            return jsonify({"error": "INSPECTION_PASSWORD (ou CAPA_PASSWORD) non défini sur le serveur."}), 503
        if _role() is None:
            return jsonify({"error": "Accès réservé à la Qualité, à l'admin et aux auditeurs."}), 401
        return fn(*a, **k)
    return w


def require_write(fn):
    @wraps(fn)
    def w(*a, **k):
        if _role() != "qualite":
            return jsonify({"error": "Profil auditeur : consultation seule, modification non autorisée."}), 403
        return fn(*a, **k)
    return w
'''),
 ('@bp.route("/api/inspection/check", methods=["POST"])\n@require_qualite\ndef check():\n    return jsonify({"ok": True})\n',
  '@bp.route("/api/inspection/check", methods=["POST"])\n@require_qualite\ndef check():\n    return jsonify({"ok": True, "role": _role()})\n'),
 ('@require_qualite\ndef creer():\n',     '@require_qualite\n@require_write\ndef creer():\n'),
 ('@require_qualite\ndef maj(iid):\n',    '@require_qualite\n@require_write\ndef maj(iid):\n'),
 ('@require_qualite\ndef note(iid):\n',   '@require_qualite\n@require_write\ndef note(iid):\n'),
 ('@require_qualite\ndef cloturer(iid):\n', '@require_qualite\n@require_write\ndef cloturer(iid):\n'),
 ('@require_qualite\ndef annuler(iid):\n', '@require_qualite\n@require_write\ndef annuler(iid):\n'),
]

print("Patch « profil auditeur lecture seule » :")
apply_repls("capa.py", CAPA)
apply_repls("inspection.py", INSP)
print("Patch terminé.")
PYEOF

# ── Rappel .env (le script n'écrit AUCUN secret) ──
if [ -f .env ] && grep -q '^AUDITEUR_PASSWORD=' .env; then
  echo "✓ AUDITEUR_PASSWORD est présent dans .env."
else
  echo "⚠  AUDITEUR_PASSWORD est ABSENT de .env."
  echo "   Tant qu'il n'est pas défini, l'auditeur n'aura accès ni à CAPA ni aux auto-inspections."
  echo "   Ajoute une ligne dans .env (remplace par le mot de passe auditeur) :"
  echo "       AUDITEUR_PASSWORD=********"
fi

# ── Reconstruction du conteneur ──
echo "== Reconstruction du conteneur (docker compose up -d --build) =="
docker compose up -d --build

echo "✓ deploy_role_auditeur.sh terminé."
