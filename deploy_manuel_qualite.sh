#!/usr/bin/env bash
# =====================================================================
#  deploy_manuel_qualite.sh
#  Ajoute l'onglet "Manuel qualité" : referentiel documentaire en
#  lecture seule, classe par familles BPF, visible par TOUS les roles
#  (operateur, qualite, admin, auditeur). L'auditeur y est donc en
#  consultation permanente. Reutilise le lecteur openReader() existant.
#
#  - Patche index.html (1 onglet + 1 branche routeur + 1 fonction).
#  - Sauvegarde .bak horodatee, idempotent (2e passage neutre).
#  - Rebuild du conteneur (index.html est copie dans l'image).
#  - Ne touche ni .env ni la base.
# =====================================================================
set -euo pipefail

APPDIR="${APPDIR:-/opt/registre-gmp}"
cd "$APPDIR"
[ -f index.html ] || { echo "ERREUR : index.html introuvable dans $APPDIR." >&2; exit 1; }

cat > _patch_manuel.py <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, shutil, datetime
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
MARK = "function viewManuel("
EDITS = [
 ("  tabs.push(['procedures','Procédures']);",
  "  tabs.push(['procedures','Procédures']);\n  tabs.push(['manuel','Manuel qualité']);"),
 ('''  else if(TAB === "comptes") viewComptes();
}

/* ---------- onglet SIGNALER ---------- */''',
  '''  else if(TAB === "comptes") viewComptes();
  else if(TAB === "manuel") viewManuel();
}

async function viewManuel(){
  $("#view").innerHTML = '<div class="card"><h2>Manuel qualité</h2>'
    + '<p class="sub">Référentiel documentaire BPF &mdash; consultation. Cliquez sur &laquo;&nbsp;Lire&nbsp;&raquo; pour ouvrir un document.</p>'
    + '<div id="mq-body"><p class="hint">Chargement&hellip;</p></div></div>';
  const body=$("#mq-body");
  let rows;
  try{ rows = await api("/api/procedures"); }
  catch(e){ body.innerHTML='<div class="err">'+esc(e.message)+'</div>'; return; }
  if(!rows.length){ body.innerHTML='<div class="empty">Aucun document disponible pour le moment.</div>'; return; }
  const ORDER=["Système qualité & amélioration continue","Production & qualité","Site & personnel","Documentation produit","Annexes & modèles"];
  const groups={};
  rows.forEach(r => { const k=r.category||"Autres"; (groups[k]=groups[k]||[]).push(r); });
  const cats=Object.keys(groups).sort((a,b)=>{
    let ia=ORDER.indexOf(a), ib=ORDER.indexOf(b);
    if(ia<0) ia=ORDER.length; if(ib<0) ib=ORDER.length;
    return ia-ib || a.localeCompare(b,'fr');
  });
  let html='';
  cats.forEach(cat => {
    const items=groups[cat].slice().sort((a,b)=>(a.code||'').localeCompare(b.code||'','fr',{numeric:true}));
    html += '<h3 style="margin-top:18px">'+esc(cat)+' <span class="muted">('+items.length+')</span></h3>'
      + items.map(r =>
        '<div class="todo" style="background:#fff"><div style="display:flex;justify-content:space-between;gap:10px;align-items:center;flex-wrap:wrap">'
        + '<div><strong>'+esc(r.code)+'</strong> &mdash; '+esc(r.title)+(r.version?' <span class="muted">v'+esc(r.version)+'</span>':'')
        + '<br><span class="muted">'+esc(r.origName)+(r.size?' &middot; '+fmtSize(r.size):'')+'</span></div>'
        + '<button class="btn btn-sm btn-ghost" data-mqview="'+r.id+'">Lire</button></div></div>'
      ).join('');
  });
  body.innerHTML=html;
  body.querySelectorAll("[data-mqview]").forEach(b => b.addEventListener("click", () => openReader(+b.dataset.mqview)));
}

/* ---------- onglet SIGNALER ---------- */'''),
]
def apply(path):
    with open(path, encoding="utf-8") as f: src = f.read()
    if MARK in src:
        print("  %s : deja patche - ignore." % path); return
    for old, new in EDITS:
        n = src.count(old)
        if n != 1:
            print("  ERREUR %s : motif %d fois (attendu 1) :\n    %r" % (path, n, old[:80])); sys.exit(2)
        src = src.replace(old, new, 1)
    bak = "%s.%s.bak" % (path, STAMP)
    shutil.copy2(path, bak)
    with open(path, "w", encoding="utf-8") as f: f.write(src)
    print("  %s : patche OK (sauvegarde %s)" % (path, os.path.basename(bak)))
print("Onglet Manuel qualite :")
apply("index.html")
print("Termine.")
PYEOF

echo "=== Application du patch ==="
if ! python3 _patch_manuel.py; then
  echo "ERREUR : patch echoue (index.html a peut-etre diverge). Aucun rebuild. Fichier d'origine intact (.bak)." >&2
  exit 3
fi

echo
echo "=== Reconstruction du conteneur ==="
docker compose up -d --build

echo
echo "=== Termine ==="
echo "Nouvel onglet 'Manuel qualite' visible par tous (auditeur en consultation)."
echo "Rafraichis la page (Ctrl+Maj+R)."
