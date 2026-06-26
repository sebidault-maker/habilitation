#!/usr/bin/env bash
# =============================================================================
#  deploy_auditeur.sh — Profil "auditeur" (consultation seule) pour les
#  registres eval / nc / cc de gmp.scientianatura.com
#
#  Usage :
#     bash deploy_auditeur.sh "MOT_DE_PASSE_AUDITEUR"
#  (le mot de passe est facultatif : sans lui, le code est posé mais le mode
#   auditeur reste INACTIF tant que AUDITEUR_PASSWORD n'est pas défini.)
#
#  - Patche en place eval.py / nc.py / cc.py (back-end : écritures -> 403 pour
#    le rôle auditeur) et eval.html / nc.html / cc.html (front : boutons masqués).
#  - Idempotent : relançable sans risque (fichiers déjà patchés = ignorés).
#  - Sauvegardes horodatées + restauration automatique en cas d'échec.
#  - Ajoute AUDITEUR_PASSWORD au .env ou au docker-compose.yml (avec
#    validation `docker compose config` et rollback si invalide).
# =============================================================================
set -euo pipefail
cd /opt/registre-gmp

AUD_PW="${1:-}"
TS="$(date +%Y%m%d-%H%M%S)"
FILES="eval.py eval.html nc.py nc.html cc.py cc.html"

echo "===================================================================="
echo " Déploiement profil AUDITEUR (consultation seule)  —  $TS"
echo "===================================================================="

# --- 0) pré-checks -----------------------------------------------------------
for f in $FILES; do
  if [ ! -f "$f" ]; then echo "!! Fichier manquant : $f — abandon."; exit 1; fi
done

# --- 1) sauvegardes ----------------------------------------------------------
echo "-- Sauvegardes (.${TS}.bak) :"
for f in $FILES; do cp "$f" "$f.$TS.bak"; echo "   $f.$TS.bak"; done

restore() {
  echo "!! Restauration des sauvegardes…"
  for f in $FILES; do [ -f "$f.$TS.bak" ] && cp "$f.$TS.bak" "$f"; done
}

# --- 2) patch des fichiers (python, en place) --------------------------------
echo "-- Application des correctifs :"
if ! python3 - <<'PYEOF'
import sys
FAIL=[]

def patch_py(fn, hdr, writes):
    s=open(fn,encoding="utf-8").read()
    if "def require_write(" in s:
        print("   =",fn,": déjà patché, ignoré"); return
    if 'PW = os.environ.get("INSPECTION_PASSWORD", "") or os.environ.get("CAPA_PASSWORD", "")' not in s:
        FAIL.append(fn+": ligne PW introuvable"); return
    s=s.replace('PW = os.environ.get("INSPECTION_PASSWORD", "") or os.environ.get("CAPA_PASSWORD", "")',
                'PW = os.environ.get("INSPECTION_PASSWORD", "") or os.environ.get("CAPA_PASSWORD", "")\nAUDITEUR = os.environ.get("AUDITEUR_PASSWORD", "")  # lecture seule (profil auditeur)',1)
    old=('def require_qualite(fn):\n'
         '    @wraps(fn)\n'
         '    def w(*a, **k):\n'
         '        if not PW:\n'
         '            return jsonify({"error": "Mot de passe qualité non défini sur le serveur."}), 503\n'
         '        if request.headers.get("%s", "") != PW:\n'
         '            return jsonify({"error": "Accès réservé à la Qualité et à l\'admin."}), 401\n'
         '        return fn(*a, **k)\n'
         '    return w')%hdr
    if old not in s: FAIL.append(fn+": bloc require_qualite introuvable"); return
    new=('def _role():\n'
         '    h = request.headers.get("%s", "")\n'
         '    if PW and h == PW:\n'
         '        return "qualite"\n'
         '    if AUDITEUR and h == AUDITEUR:\n'
         '        return "auditeur"\n'
         '    return None\n\n'
         'def require_qualite(fn):\n'
         '    @wraps(fn)\n'
         '    def w(*a, **k):\n'
         '        if not PW:\n'
         '            return jsonify({"error": "Mot de passe qualité non défini sur le serveur."}), 503\n'
         '        if _role() is None:\n'
         '            return jsonify({"error": "Accès réservé à la Qualité, à l\'admin et aux auditeurs."}), 401\n'
         '        return fn(*a, **k)\n'
         '    return w\n\n'
         'def require_write(fn):\n'
         '    @wraps(fn)\n'
         '    def w(*a, **k):\n'
         '        if _role() != "qualite":\n'
         '            return jsonify({"error": "Profil auditeur : consultation seule, modification non autorisée."}), 403\n'
         '        return fn(*a, **k)\n'
         '    return w')%hdr
    s=s.replace(old,new,1)
    s=s.replace('def check(): return jsonify({"ok": True})',
                'def check(): return jsonify({"ok": True, "role": _role()})',1)
    for w in writes:
        pat="@require_qualite\ndef %s("%w
        if pat not in s: FAIL.append(fn+": endpoint "+w+" introuvable"); return
        s=s.replace(pat,"@require_qualite\n@require_write\ndef %s("%w,1)
    if 'def require_write(' not in s or '"role": _role()' not in s:
        FAIL.append(fn+": vérif post-patch échouée"); return
    open(fn,"w",encoding="utf-8").write(s); print("   ✓",fn)

def patch_eval_html(fn="eval.html"):
    s=open(fn,encoding="utf-8").read()
    if 'ROLE==="auditeur"' in s: print("   =",fn,": déjà patché, ignoré"); return
    o=s
    s=s.replace('<span class="role">QUALITÉ / ADMIN</span>','<span class="role" id="roleBadge">QUALITÉ / ADMIN</span>',1)
    s=s.replace('async function unlock(){','var ROLE="";\nasync function unlock(){',1)
    s=s.replace('if(r.ok){document.getElementById("gate").style.display="none";document.getElementById("app").style.display="block";startup();}',
                'if(r.ok){const j=await r.json().catch(()=>({}));ROLE=j.role||"";document.getElementById("gate").style.display="none";document.getElementById("app").style.display="block";startup();}',1)
    s=s.replace('function startup(){\n  var t=qs();',
                'function startup(){\n  if(ROLE==="auditeur"){document.getElementById("btnNewBlanc").style.display="none";document.getElementById("btnNewAuto").style.display="none";var rb=document.getElementById("roleBadge");if(rb)rb.textContent="AUDITEUR · LECTURE SEULE";}\n  var t=qs();',1)
    s=s.replace('async function newEval(type){\n','async function newEval(type){\n  if(ROLE==="auditeur")return;\n',1)
    s=s.replace('function setLocked(locked){\n  document.querySelectorAll',
                'function setLocked(locked){\n  if(ROLE==="auditeur")locked=true;\n  document.querySelectorAll',1)
    s=s.replace('if(locked){lm.style.display="block";lm.textContent=CURRENT.statut==="cloture"?"Évaluation clôturée — lecture seule.":"Évaluation annulée — lecture seule."+(CURRENT.motif?(" Motif : "+CURRENT.motif):"");}',
                'if(locked){lm.style.display="block";lm.textContent=ROLE==="auditeur"?"Consultation seule — profil auditeur (aucune modification possible).":(CURRENT.statut==="cloture"?"Évaluation clôturée — lecture seule.":(CURRENT.statut==="annule"?("Évaluation annulée — lecture seule."+(CURRENT.motif?(" Motif : "+CURRENT.motif):"")):"Lecture seule."));}',1)
    if s.count('ROLE==="auditeur"')<4: FAIL.append(fn+": correctifs front incomplets"); return
    open(fn,"w",encoding="utf-8").write(s); print("   ✓",fn)

def patch_generic_html(fn):
    s=open(fn,encoding="utf-8").read()
    if 'ROLE==="auditeur"' in s: print("   =",fn,": déjà patché, ignoré"); return
    s=s.replace('<span class="role">QUALITÉ / ADMIN</span>','<span class="role" id="roleBadge">QUALITÉ / ADMIN</span>',1)
    s=s.replace('<button class="primary" onclick="openNew()">','<button class="primary" id="btnNew" onclick="openNew()">',1)
    s=s.replace('const PW_KEY=CFG.pwKey;let CURRENT=null,LIST=[];','const PW_KEY=CFG.pwKey;let CURRENT=null,LIST=[],ROLE="";',1)
    s=s.replace('if(r.ok){document.getElementById("gate").style.display="none";document.getElementById("app").style.display="block";buildStatic();load();}',
                'if(r.ok){const j=await r.json().catch(()=>({}));ROLE=j.role||"";document.getElementById("gate").style.display="none";document.getElementById("app").style.display="block";buildStatic();load();applyRole();}',1)
    s=s.replace('async function load(){','function applyRole(){if(ROLE==="auditeur"){var b=document.getElementById("btnNew");if(b)b.style.display="none";var rb=document.getElementById("roleBadge");if(rb)rb.textContent="AUDITEUR · LECTURE SEULE";}}\nasync function load(){',1)
    s=s.replace('function openNew(){CURRENT=null;','function openNew(){if(ROLE==="auditeur")return;CURRENT=null;',1)
    s=s.replace('var locked=CFG.lock.indexOf(CURRENT.statut)>-1;\n  CFG.fields.forEach',
                'var locked=CFG.lock.indexOf(CURRENT.statut)>-1;\n  if(ROLE==="auditeur")locked=true;\n  CFG.fields.forEach',1)
    s=s.replace('if(a.kind==="note"){b.style.marginLeft="auto";b.disabled=(CFG.dim.indexOf(CURRENT.statut)>-1);}',
                'if(a.kind==="note"){b.style.marginLeft="auto";b.disabled=(CFG.dim.indexOf(CURRENT.statut)>-1)||ROLE==="auditeur";}',1)
    if s.count('ROLE==="auditeur"')<4: FAIL.append(fn+": correctifs front incomplets"); return
    open(fn,"w",encoding="utf-8").write(s); print("   ✓",fn)

patch_py("eval.py","X-Eval-Password",["creer","sauver","cloturer","annuler"])
patch_py("nc.py","X-NC-Password",["creer","maj","note","cloturer","annuler"])
patch_py("cc.py","X-CC-Password",["creer","maj","approuver","refuser","cloturer","annuler","note"])
patch_eval_html("eval.html")
patch_generic_html("nc.html")
patch_generic_html("cc.html")

if FAIL:
    print("\n!! ÉCHEC DU PATCH :")
    for x in FAIL: print("   -",x)
    sys.exit(3)
print("-- Correctifs appliqués.")
PYEOF
then :; else echo "!! Patch interrompu."; restore; exit 1; fi

# --- 3) compile-check des back-ends -----------------------------------------
for f in eval.py nc.py cc.py; do
  if ! python3 -c "import ast,sys;ast.parse(open('$f').read())" 2>/dev/null; then
    echo "!! $f ne compile pas — restauration."; restore; exit 1; fi
done
echo "-- Back-ends OK (compilation)."

# --- 4) AUDITEUR_PASSWORD : .env ou docker-compose.yml -----------------------
if [ -n "$AUD_PW" ]; then
  echo "-- Configuration de AUDITEUR_PASSWORD :"
  COMPOSE="docker-compose.yml"; [ -f "$COMPOSE" ] || COMPOSE="compose.yaml"
  CFG_BAK=""
  if [ -f ".env" ] && grep -q '^INSPECTION_PASSWORD=' .env; then
    cp .env ".env.$TS.bak"; CFG_BAK=".env"
    if grep -q '^AUDITEUR_PASSWORD=' .env; then
      sed -i "s|^AUDITEUR_PASSWORD=.*|AUDITEUR_PASSWORD=$AUD_PW|" .env
    else
      printf 'AUDITEUR_PASSWORD=%s\n' "$AUD_PW" >> .env
    fi
    echo "   .env mis à jour."
  elif [ -f "$COMPOSE" ] && grep -q 'INSPECTION_PASSWORD' "$COMPOSE"; then
    cp "$COMPOSE" "$COMPOSE.$TS.bak"; CFG_BAK="$COMPOSE"
    python3 - "$COMPOSE" "$AUD_PW" <<'PYC'
import sys,re
fn,pw=sys.argv[1],sys.argv[2]
s=open(fn,encoding="utf-8").read().splitlines(True)
out=[]; done=False
has=any("AUDITEUR_PASSWORD" in l for l in s)
for l in s:
    if "AUDITEUR_PASSWORD" in l and not done:
        ind=re.match(r'\s*-?\s*',l).group(0)
        if "=" in l: out.append(ind+("AUDITEUR_PASSWORD=%s\n"%pw) if l.lstrip().startswith("-") else re.sub(r'AUDITEUR_PASSWORD.*',"AUDITEUR_PASSWORD=%s"%pw,l))
        else: out.append(re.sub(r'AUDITEUR_PASSWORD\s*:.*',"AUDITEUR_PASSWORD: \"%s\""%pw,l))
        done=True; continue
    out.append(l)
    if (not has) and (not done) and "INSPECTION_PASSWORD" in l:
        m=re.match(r'(\s*)(-\s*)?INSPECTION_PASSWORD(\s*[:=])',l)
        if m:
            ind=m.group(1); dash="- " if m.group(2) else ""; sep=":" if ":" in m.group(3) else "="
            if sep=="=": out.append("%s%sAUDITEUR_PASSWORD=%s\n"%(ind,dash,pw))
            else: out.append("%s%sAUDITEUR_PASSWORD: \"%s\"\n"%(ind,dash,pw))
            done=True
open(fn,"w",encoding="utf-8").write("".join(out))
print("   %s mis à jour."%fn)
PYC
  else
    echo "   ?? Impossible de localiser INSPECTION_PASSWORD (ni .env ni $COMPOSE)."
    echo "      Ajoute AUDITEUR_PASSWORD=$AUD_PW au même endroit que INSPECTION_PASSWORD,"
    echo "      puis relance : docker compose up -d --build"
  fi
  # validation compose
  if [ -n "$CFG_BAK" ]; then
    if docker compose config -q 2>/dev/null; then
      echo "   docker compose config : OK."
    else
      echo "!! docker-compose invalide après modif — restauration de $CFG_BAK."
      cp "$CFG_BAK.$TS.bak" "$CFG_BAK"
      echo "   (le code reste patché ; ajoute AUDITEUR_PASSWORD manuellement.)"
    fi
  fi
else
  echo "-- (Aucun mot de passe fourni : mode auditeur INACTIF tant que"
  echo "    AUDITEUR_PASSWORD n'est pas défini. Voir la note en fin de script.)"
fi

# --- 5) rebuild --------------------------------------------------------------
echo "-- Reconstruction du conteneur…"
docker compose up -d --build

echo "===================================================================="
echo " Profil AUDITEUR déployé."
echo "   • Back-end : toute écriture renvoie 403 avec le mot de passe auditeur."
echo "   • Front    : boutons Créer/Enregistrer/Clôturer/Annuler masqués,"
echo "                badge « AUDITEUR · LECTURE SEULE », champs en lecture seule."
echo "   • Registres couverts : /eval (audit blanc + auto-inspection), /nc, /cc."
echo
echo "   Donne à l'auditeur le mot de passe auditeur ; il consulte via l'onglet"
echo "   Qualité / Admin (ou directement /eval?type=blanc, /eval?type=auto, /nc, /cc)."
echo
echo "   NB : si tu n'as pas passé de mot de passe, ajoute dans .env (ou compose) :"
echo "        AUDITEUR_PASSWORD=ton_mot_de_passe   puis  docker compose up -d --build"
echo "   Restauration code : cp <fichier>.$TS.bak <fichier> ; docker compose up -d --build"
echo "===================================================================="
