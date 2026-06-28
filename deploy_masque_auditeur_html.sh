#!/usr/bin/env bash
# =====================================================================
# deploy_masque_auditeur_html.sh  —  Laboratoires Scientia Natura (GMP)
# Masque proprement les commandes d'écriture pour le profil AUDITEUR
# dans capa.html et inspection.html (badge « Auditeur · Lecture seule »,
# bouton « + Nouveau » caché, fiche en lecture seule).
# Aligné sur cc.html / eval.html, déjà à jour.
#
# PRÉREQUIS : avoir déjà appliqué deploy_role_auditeur.sh (le backend doit
# renvoyer le rôle via /check). Sans lui : aucun effet, mais aucune casse.
#
# Sûr & relançable : valide TOUS les motifs AVANT d'écrire (pas d'application
# partielle), sauvegarde horodatée de chaque fichier, idempotent (marqueur
# ROLE==="auditeur"), puis reconstruit le conteneur.
# NE TOUCHE NI .env NI *.db.
# =====================================================================
set -euo pipefail
cd /opt/registre-gmp

echo "== Déploiement : masquage profil auditeur (capa.html + inspection.html) =="

for f in capa.html inspection.html docker-compose.yml; do
  [ -f "$f" ] || { echo "ERREUR : $f introuvable dans $(pwd)." >&2; exit 1; }
done

python3 - <<'PYEOF'
import os, sys, shutil, datetime
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
MARK = 'ROLE==="auditeur"'

def transform(path, repls):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if MARK in src:
        print("  %-16s : déjà patché — ignoré." % path); return None
    for old, new in repls:
        n = src.count(old)
        if n != 1:
            print("  ERREUR %s : motif présent %d fois (attendu 1) :\n    %r"
                  % (path, n, old[:80])); sys.exit(2)
        src = src.replace(old, new, 1)
    return src

CAPA = [
 ('let PW="", LIST=[];',
  'let PW="", LIST=[], ROLE="";'),
 ('''  const r=await api("POST","/api/capa/check");
  if(r.status===200){try{sessionStorage.setItem("capa_pw",PW);}catch(e){}entered();}''',
  '''  const r=await api("POST","/api/capa/check");
  if(r.status===200){ROLE=(r.data&&r.data.role)||"";try{sessionStorage.setItem("capa_pw",PW);}catch(e){}entered();}'''),
 ('''async function entered(){
  $("#gate").classList.add("hidden");$("#app").classList.remove("hidden");
  await loadDevs();await load();
  if(qs("new")==="1") openNew({origine:qs("origine")||""});
}''',
  '''async function entered(){
  $("#gate").classList.add("hidden");$("#app").classList.remove("hidden");
  applyRole();
  await loadDevs();await load();
  if(qs("new")==="1"&&ROLE!=="auditeur") openNew({origine:qs("origine")||""});
}
function applyRole(){
  if(ROLE!=="auditeur")return;
  var b=$("#newBtn");if(b)b.style.display="none";
  var bg=document.querySelector(".topbar .badge");if(bg)bg.textContent="Auditeur · Lecture seule";
}'''),
 ('function openNew(prefill){\n  prefill=prefill||{};',
  'function openNew(prefill){\n  if(ROLE==="auditeur")return;\n  prefill=prefill||{};'),
 ('  const closed=r.statut==="cloturee"||r.statut==="annulee";',
  '  const closed=r.statut==="cloturee"||r.statut==="annulee"||ROLE==="auditeur";'),
 ('if(PW){api("POST","/api/capa/check").then(r=>{if(r.status===200)entered();});}',
  'if(PW){api("POST","/api/capa/check").then(r=>{if(r.status===200){ROLE=(r.data&&r.data.role)||"";entered();}});}'),
]

INSP = [
 ('let CURRENT=null, LIST=[];',
  'let CURRENT=null, LIST=[], ROLE="";'),
 ('''  if(r.ok){
    document.getElementById("gate").style.display="none";
    document.getElementById("app").style.display="block";
    load();
  }else{''',
  '''  if(r.ok){
    const j=await r.json().catch(()=>({}));ROLE=j.role||"";
    document.getElementById("gate").style.display="none";
    document.getElementById("app").style.display="block";
    applyRole();
    load();
  }else{'''),
 ('function lock(msg){',
  '''function applyRole(){
  if(ROLE!=="auditeur")return;
  var nb=document.querySelector('button[onclick="openNew()"]');if(nb)nb.style.display="none";
  var rb=document.querySelector(".role");if(rb)rb.textContent="AUDITEUR · LECTURE SEULE";
}
function lock(msg){'''),
 ('function openNew(){\n  CURRENT=null;',
  'function openNew(){\n  if(ROLE==="auditeur")return;\n  CURRENT=null;'),
 ('  const locked=(CURRENT.statut==="cloturee"||CURRENT.statut==="annulee");',
  '  const locked=(CURRENT.statut==="cloturee"||CURRENT.statut==="annulee"||ROLE==="auditeur");'),
 ('    if(b.textContent.indexOf("Note")>-1){b.disabled=(CURRENT.statut==="annulee");return;}',
  '    if(b.textContent.indexOf("Note")>-1){b.disabled=(CURRENT.statut==="annulee")||ROLE==="auditeur";return;}'),
]

print("Masquage profil auditeur (HTML) :")
# 1) On valide TOUT avant d'écrire quoi que ce soit
plan = {}
for path, repls in (("capa.html", CAPA), ("inspection.html", INSP)):
    res = transform(path, repls)
    if res is not None:
        plan[path] = res
# 2) On écrit (avec sauvegarde) seulement après validation complète
for path, newsrc in plan.items():
    bak = "%s.%s.bak" % (path, STAMP)
    shutil.copy2(path, bak)
    with open(path, "w", encoding="utf-8") as f:
        f.write(newsrc)
    # garde-fou : fichier non tronqué + marqueur présent
    chk = open(path, encoding="utf-8").read()
    if MARK not in chk or "</html>" not in chk.lower():
        shutil.copy2(bak, path)
        print("  ERREUR post-écriture sur %s — restauré." % path); sys.exit(3)
    print("  %-16s : patché OK (sauvegarde %s)" % (path, os.path.basename(bak)))
print("Patch terminé.")
PYEOF

echo "== Reconstruction du conteneur (docker compose up -d --build) =="
docker compose up -d --build

echo "✓ deploy_masque_auditeur_html.sh terminé."
echo "  Pense à vider le cache navigateur (Ctrl+Maj+R) pour voir le changement."
