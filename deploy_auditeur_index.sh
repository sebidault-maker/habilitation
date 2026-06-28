#!/usr/bin/env bash
# =====================================================================
# deploy_auditeur_index.sh  —  Laboratoires Scientia Natura (GMP)
# Donne au profil AUDITEUR l'accès en LECTURE à tous les onglets de
# l'appli principale (index.html) et masque les commandes d'écriture :
#   - can() aligné sur le backend (auditeur = rang 2, comme Qualité)
#   - onglet "Signaler un écart" retiré (écriture) ; atterrissage sur
#     "Suivi qualité"
#   - fiche déviation en lecture seule (champs désactivés, boutons
#     Enregistrer / Annuler retirés)
#   - boutons "Passer le test" (formation) et "J'ai lu" (procédures) retirés
#
# Sûr & relançable : sauvegarde horodatée, garde-fou (marqueur + </html>),
# restauration auto si problème, idempotent (marqueur auditeur:2).
# NE TOUCHE NI .env NI *.db.
# =====================================================================
set -euo pipefail
cd /opt/registre-gmp

echo "== Déploiement : accès lecture seule auditeur (index.html) =="

for f in index.html docker-compose.yml; do
  [ -f "$f" ] || { echo "ERREUR : $f introuvable dans $(pwd)." >&2; exit 1; }
done

python3 - <<'PYEOF'
import os, sys, shutil, datetime
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
MARK = "auditeur:2"

REPLS = [
 ('function can(role){ const rank={operator:1,quality:2,admin:3}; return rank[ME.role] >= rank[role]; }',
  'function can(role){ const rank={operator:1,quality:2,admin:3,auditeur:2}; return rank[ME.role] >= rank[role]; }'),

 ('''  const tabs = [['signaler','Signaler un écart']];
  if(can("quality")) tabs.push(['suivi','Suivi qualité']);
  tabs.push(['formation','Formation']);
  tabs.push(['habilitations','Habilitations']);
  tabs.push(['procedures','Procédures']);
  tabs.push(['planning','Planning']);
  if(can("admin")) tabs.push(['comptes','Comptes']);
  if(!tabs.find(t => t[0]===TAB)) TAB = "signaler";''',
  '''  const tabs = [];
  if(ME.role!=="auditeur") tabs.push(['signaler','Signaler un écart']);
  if(can("quality")) tabs.push(['suivi','Suivi qualité']);
  tabs.push(['formation','Formation']);
  tabs.push(['habilitations','Habilitations']);
  tabs.push(['procedures','Procédures']);
  tabs.push(['planning','Planning']);
  if(can("admin")) tabs.push(['comptes','Comptes']);
  if(!tabs.find(t => t[0]===TAB)) TAB = (tabs[0] && tabs[0][0]) || "signaler";'''),

 ('  const impacts=["Aucun","Mineur","Majeur"]; const annulee=d.statut==="annulee";',
  '  const impacts=["Aucun","Mineur","Majeur"]; const annulee=d.statut==="annulee"; const ro=annulee||(ME.role==="auditeur");'),

 ('''    + '<div class="btn-row">'+(annulee?'':'<button class="btn btn-primary" id="e-save">Enregistrer</button>')''',
  '''    + '<div class="btn-row">'+(ro?'':'<button class="btn btn-primary" id="e-save">Enregistrer</button>')'''),

 ('''    + (annulee?'':'<div class="btn-row"><button class="btn btn-ghost" id="e-cancel" style="color:var(--red);border-color:#E3C3BC">Annuler la fiche</button></div>')''',
  '''    + (ro?'':'<div class="btn-row"><button class="btn btn-ghost" id="e-cancel" style="color:var(--red);border-color:#E3C3BC">Annuler la fiche</button></div>')'''),

 ('''  if(!annulee){ $("#e-save").addEventListener("click", () => saveSheet(d.id)); $("#e-cancel").addEventListener("click", () => cancelSheet(d.id)); }''',
  '''  if(!ro){ $("#e-save").addEventListener("click", () => saveSheet(d.id)); $("#e-cancel").addEventListener("click", () => cancelSheet(d.id)); }
  if(ME.role==="auditeur"){ document.querySelectorAll("#sheet select,#sheet textarea,#sheet input").forEach(function(el){el.disabled=true;}); }'''),

 (''''<button class="btn btn-sm '+cls+'" data-take="'+m.id+'"'+(m.nbQuestions?'':' disabled')+'>'+label+'</button></div></div>';''',
  '''(ME.role==="auditeur"?'':'<button class="btn btn-sm '+cls+'" data-take="'+m.id+'"'+(m.nbQuestions?'':' disabled')+'>'+label+'</button>')+'</div></div>';'''),

 (''''<button class="btn btn-primary" id="rdr-ack"'+(gated?' disabled':'')+'>''',
  ''''<button class="btn btn-primary" id="rdr-ack"'+(gated||ME.role==="auditeur"?' disabled':'')+(ME.role==="auditeur"?' style="display:none"':'')+'>'''),
]

path = "index.html"
with open(path, encoding="utf-8") as f:
    src = f.read()
if MARK in src:
    print("  index.html : déjà patché — ignoré."); sys.exit(0)
for old, new in REPLS:
    n = src.count(old)
    if n != 1:
        print("  ERREUR : motif %d fois (attendu 1) :\n    %r" % (n, old[:80])); sys.exit(2)
    src = src.replace(old, new, 1)
bak = "%s.%s.bak" % (path, STAMP)
shutil.copy2(path, bak)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
chk = open(path, encoding="utf-8").read()
if MARK not in chk or "</html>" not in chk.lower():
    shutil.copy2(bak, path)
    print("  ERREUR post-écriture — restauré depuis %s." % os.path.basename(bak)); sys.exit(3)
print("  index.html : patché OK (sauvegarde %s)" % os.path.basename(bak))
PYEOF

echo "== Reconstruction du conteneur (docker compose up -d --build) =="
docker compose up -d --build

echo "✓ deploy_auditeur_index.sh terminé."
echo "  Vide le cache navigateur (Ctrl+Maj+R) et reconnecte le compte Auditeur."
