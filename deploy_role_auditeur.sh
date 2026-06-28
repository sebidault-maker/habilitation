#!/usr/bin/env bash
# =============================================================================
#  deploy_role_auditeur.sh — Ajoute le rôle "Auditeur (lecture seule)" à
#  l'application principale (page de connexion + comptes) de gmp.scientianatura.com
#
#  Effet :
#   - app.py : nouveau rôle `auditeur` (rang lecture = Qualité) + filet global
#     dans gate() -> 403 sur TOUTE écriture (POST/PUT/DELETE) pour ce rôle,
#     sauf login / logout / change-password. _can_edit_planning -> False.
#   - index.html : option "Auditeur (lecture seule)" dans les menus de rôle
#     (création + modification de compte).
#
#  Idempotent (relançable). Sauvegardes horodatées + restauration auto si échec.
#  Usage :  bash deploy_role_auditeur.sh
# =============================================================================
set -euo pipefail
cd /opt/registre-gmp

TS="$(date +%Y%m%d-%H%M%S)"
FILES="app.py index.html"

echo "===================================================================="
echo " Rôle AUDITEUR (lecture seule) — application principale  —  $TS"
echo "===================================================================="

for f in $FILES; do
  [ -f "$f" ] || { echo "!! Fichier manquant : $f — abandon."; exit 1; }
done

echo "-- Sauvegardes :"
for f in $FILES; do cp "$f" "$f.$TS.bak"; echo "   $f.$TS.bak"; done

restore() {
  echo "!! Restauration des sauvegardes…"
  for f in $FILES; do [ -f "$f.$TS.bak" ] && cp "$f.$TS.bak" "$f"; done
}

echo "-- Application des correctifs :"
if python3 - <<'PYEOF'
import sys
FAIL=[]

def patch_app(fn):
    s=open(fn,encoding="utf-8").read()
    if "AUDITEUR_WRITE_WHITELIST" in s:
        print("   = app.py déjà patché, ignoré"); return
    if 'ROLES = ("operator", "quality", "admin")' not in s:
        FAIL.append("app.py : ligne ROLES introuvable"); return
    s=s.replace('ROLES = ("operator", "quality", "admin")',
                'ROLES = ("operator", "quality", "admin", "auditeur")',1)
    s=s.replace('ROLE_RANK = {"operator": 1, "quality": 2, "admin": 3}',
                'ROLE_RANK = {"operator": 1, "quality": 2, "admin": 3, "auditeur": 2}',1)
    s=s.replace('ROLE_LABELS = {"operator": "Opérateur", "quality": "Qualité", "admin": "Administrateur"}',
                'ROLE_LABELS = {"operator": "Opérateur", "quality": "Qualité", "admin": "Administrateur", "auditeur": "Auditeur (lecture seule)"}',1)
    s=s.replace('PUBLIC_PATHS = {"/", "/health", "/api/login", "/api/me", "/api/logout"}',
                'PUBLIC_PATHS = {"/", "/health", "/api/login", "/api/me", "/api/logout"}\n'
                '# Profil auditeur : lecture seule. Seules ces routes d\'ecriture lui restent permises.\n'
                'AUDITEUR_WRITE_WHITELIST = {"/api/change-password", "/api/logout"}',1)
    anchor=('    if p in PUBLIC_PATHS or not p.startswith("/api/"):\n'
            '        return\n'
            '    if not session.get("uid"):\n'
            '        return jsonify(error="Authentification requise."), 401')
    if anchor not in s:
        FAIL.append("app.py : gate() introuvable"); return
    s=s.replace(anchor, anchor+
        ('\n    if session.get("role") == "auditeur" and request.method in ("POST", "PUT", "DELETE", "PATCH") \\\n'
         '            and p not in AUDITEUR_WRITE_WHITELIST:\n'
         '        return jsonify(error="Profil auditeur : consultation seule, aucune modification autorisee."), 403'),1)
    anchor2=('    Si pkey est None : renvoie True si la personne peut éditer au moins un planning."""\n'
             '    if session.get("role") == "admin":')
    if anchor2 not in s:
        FAIL.append("app.py : _can_edit_planning introuvable"); return
    s=s.replace(anchor2,
        ('    Si pkey est None : renvoie True si la personne peut éditer au moins un planning."""\n'
         '    if session.get("role") == "auditeur":\n'
         '        return False\n'
         '    if session.get("role") == "admin":'),1)
    for needle in ['"auditeur": 2','AUDITEUR_WRITE_WHITELIST','consultation seule, aucune modification']:
        if needle not in s: FAIL.append("app.py : post-verif manque "+needle); return
    open(fn,"w",encoding="utf-8").write(s); print("   \u2713 app.py")

def patch_html(fn):
    s=open(fn,encoding="utf-8").read()
    if 'auditeur:"Auditeur (lecture seule)"' in s:
        print("   = index.html déjà patché, ignoré"); return
    if 'const ROLE_LABELS = {operator:"Opérateur", quality:"Qualité", admin:"Administrateur"};' not in s:
        FAIL.append("index.html : ROLE_LABELS introuvable"); return
    s=s.replace('const ROLE_LABELS = {operator:"Opérateur", quality:"Qualité", admin:"Administrateur"};',
                'const ROLE_LABELS = {operator:"Opérateur", quality:"Qualité", admin:"Administrateur", auditeur:"Auditeur (lecture seule)"};',1)
    a_create="+ '<option value=\"admin\">Administrateur (gère les comptes)</option></select></div>'"
    if a_create not in s:
        FAIL.append("index.html : menu création introuvable"); return
    s=s.replace(a_create,
                "+ '<option value=\"admin\">Administrateur (gère les comptes)</option>'\n"
                "    + '<option value=\"auditeur\">Auditeur (lecture seule)</option></select></div>'",1)
    a_edit="+ ['operator','quality','admin'].map(r => '<option value=\"'+r+'\"'"
    if a_edit not in s:
        FAIL.append("index.html : menu édition introuvable"); return
    s=s.replace(a_edit,"+ ['operator','quality','admin','auditeur'].map(r => '<option value=\"'+r+'\"'",1)
    for needle in ['auditeur:"Auditeur (lecture seule)"','value="auditeur">Auditeur (lecture seule)',
                   "['operator','quality','admin','auditeur']"]:
        if needle not in s: FAIL.append("index.html : post-verif manque "+needle); return
    open(fn,"w",encoding="utf-8").write(s); print("   \u2713 index.html")

patch_app("app.py")
patch_html("index.html")
if FAIL:
    print("\n!! ÉCHEC :")
    for x in FAIL: print("   -",x)
    sys.exit(3)
print("-- Correctifs appliqués.")
PYEOF
then :; else echo "!! Patch interrompu."; restore; exit 1; fi

echo "-- Vérification syntaxe app.py :"
if ! python3 -c "import ast; ast.parse(open('app.py').read())" 2>/dev/null; then
  echo "!! app.py ne compile pas — restauration."; restore; exit 1
fi
echo "   app.py OK."

echo "-- Reconstruction du conteneur…"
docker compose up -d --build

echo "===================================================================="
echo " Rôle AUDITEUR déployé."
echo "   Crée maintenant le compte auditeur : onglet Comptes -> Nouveau compte"
echo "      Rôle = « Auditeur (lecture seule) »"
echo "      Identifiant : auditeur   Nom : Bernard PLAU (FACOPHAR)"
echo "      Mot de passe temporaire : (au choix, 8+ car.)"
echo "   L'auditeur entre sur la plateforme, voit déviations / qualité / procédures,"
echo "   et reçoit 403 sur toute modification."
echo "   Restauration : cp app.py.$TS.bak app.py ; cp index.html.$TS.bak index.html ; docker compose up -d --build"
echo "===================================================================="
