#!/usr/bin/env bash
# =============================================================================
#  deploy_cc_gravite.sh
#  Plateforme GMP Scientia Natura — suites du pre-audit du 22-23/07/2026.
#
#  LOT 1 (2 demandes de l'auditeur B. PLAU) :
#   1) Demande de changement : ajout du niveau de gravite
#      (mineur / majeur / critique) — champ liste deroulante, colonne base,
#      colonne liste et export CSV.
#   2) Onglet « Suivi qualite » : acces direct au Change Control et aux
#      registres qualite (le Change Control n'etait accessible que depuis
#      l'onglet « Qualite / Admin »).
#
#  Sûr et relançable : sauvegardes .bak horodatees, patchs idempotents,
#  controle de compilation de cc.py avec restauration automatique,
#  migration de base non destructive (ALTER TABLE ... ADD COLUMN),
#  puis reconstruction Docker. Aucune donnee existante n'est modifiee.
# =============================================================================
set -euo pipefail

cd /opt/registre-gmp

TS="$(date +%Y%m%d-%H%M%S)"
echo "== Deploiement gravite Change Control + acces registres ($TS) =="

for f in cc.py cc.html index.html; do
  [ -f "$f" ] || { echo "ERREUR : $f introuvable dans $(pwd)"; exit 1; }
done

cp -p cc.py     "cc.py.$TS.bak"
cp -p cc.html   "cc.html.$TS.bak"
cp -p index.html "index.html.$TS.bak"
echo "✓ Sauvegardes horodatees : *.$TS.bak"

python3 - <<'PYEOF'
import io, sys

def read(p):  return io.open(p, encoding="utf-8").read()
def write(p, s): io.open(p, "w", encoding="utf-8").write(s)

changed = []

# ---------------------------------------------------------------- cc.py -----
cc = read("cc.py")
if '"gravite"' in cc and "ADD COLUMN gravite" in cc:
    print("• cc.py : deja patche, on saute.")
else:
    # 1. champ editable
    a = '"date_mise_en_oeuvre", "verification_post")'
    if a not in cc: sys.exit("ERREUR : ancre EDITABLES introuvable dans cc.py.")
    cc = cc.replace(a, '"date_mise_en_oeuvre", "verification_post", "gravite")', 1)

    # 2. migration de base (non destructive, vaut aussi pour une base neuve)
    a = ('            ts TEXT NOT NULL, type TEXT NOT NULL, note TEXT DEFAULT \'\')"""'
         ')')
    if a not in cc: sys.exit("ERREUR : ancre init_db introuvable dans cc.py.")
    cc = cc.replace(a, a + """
        cols = [r[1] for r in c.execute("PRAGMA table_info(cc)").fetchall()]
        if "gravite" not in cols:
            c.execute("ALTER TABLE cc ADD COLUMN gravite TEXT DEFAULT ''")""", 1)

    # 3. creation : enregistrer la gravite des la demande
    a = ('        c.execute("INSERT INTO cc (id,annee,statut,description,demandeur,date_demande,"\n'
         '                  "type_changement,justification,created_at) VALUES (?,?,?,?,?,?,?,?,?)",\n'
         '                  (iid, year, "demande", desc, (d.get("demandeur") or "").strip(), dd,\n'
         '                   (d.get("type_changement") or "").strip(),\n'
         '                   (d.get("justification") or "").strip(), now))')
    if a not in cc: sys.exit("ERREUR : ancre creer() introuvable dans cc.py.")
    b = ('        c.execute("INSERT INTO cc (id,annee,statut,description,demandeur,date_demande,"\n'
         '                  "type_changement,justification,gravite,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",\n'
         '                  (iid, year, "demande", desc, (d.get("demandeur") or "").strip(), dd,\n'
         '                   (d.get("type_changement") or "").strip(),\n'
         '                   (d.get("justification") or "").strip(),\n'
         '                   (d.get("gravite") or "").strip(), now))')
    cc = cc.replace(a, b, 1)

    # 4. export CSV
    a = '            "description", "justification", "evaluation_impact", "actions_associees",'
    if a not in cc: sys.exit("ERREUR : ancre export_csv introuvable dans cc.py.")
    cc = cc.replace(a, '            "gravite", "description", "justification", "evaluation_impact",\n'
                       '            "actions_associees",', 1)
    write("cc.py", cc); changed.append("cc.py")
    print("✓ cc.py : champ gravite (editable, base, creation, export CSV).")

# -------------------------------------------------------------- cc.html -----
h = read("cc.html")
if '"gravite"' in h:
    print("• cc.html : deja patche, on saute.")
else:
    # 1. colonne dans la liste
    a = '["demandeur", "Demandeur"]], "fields":'
    if a not in h: sys.exit("ERREUR : ancre CFG.columns introuvable dans cc.html.")
    h = h.replace(a, '["demandeur", "Demandeur"], ["gravite", "Gravit\u00e9"]], "fields":', 1)

    # 2. champ du formulaire (place juste avant la description)
    a = '["description", "Description du changement", "textarea", true],'
    if a not in h: sys.exit("ERREUR : ancre CFG.fields introuvable dans cc.html.")
    h = h.replace(a, '["gravite", "Gravit\u00e9 (mineur / majeur / critique)", "select", false, '
                     '["", "mineur", "majeur", "critique"]], ' + a, 1)

    # 3. gravite saisissable des la creation
    a = '"createFields": ["description", "demandeur", "date_demande", "type_changement", "justification"]'
    if a not in h: sys.exit("ERREUR : ancre createFields introuvable dans cc.html.")
    h = h.replace(a, '"createFields": ["description", "demandeur", "date_demande", '
                     '"type_changement", "justification", "gravite"]', 1)

    # 4. le moteur de rendu ne connaissait que input/textarea : support des listes
    a = ('    var inner=f[2]==="textarea"?\'<textarea id="f_\'+f[0]+\'"></textarea>\''
         ':\'<input id="f_\'+f[0]+\'" type="\'+(f[2]||"text")+\'">\';')
    if a not in h: sys.exit("ERREUR : ancre du moteur de rendu introuvable dans cc.html.")
    b = ('    var inner;\n'
         '    if(f[2]==="textarea"){ inner=\'<textarea id="f_\'+f[0]+\'"></textarea>\'; }\n'
         '    else if(f[2]==="select"){ inner=\'<select id="f_\'+f[0]+\'">\'+(f[4]||[""]).map(function(o){\n'
         '        return \'<option value="\'+o+\'">\'+(o?o.charAt(0).toUpperCase()+o.slice(1):"\\u2014")+\'</option>\';\n'
         '      }).join("")+\'</select>\'; }\n'
         '    else { inner=\'<input id="f_\'+f[0]+\'" type="\'+(f[2]||"text")+\'">\'; }')
    h = h.replace(a, b, 1)
    write("cc.html", h); changed.append("cc.html")
    print("✓ cc.html : liste deroulante Gravite + colonne dans le registre.")

# ------------------------------------------------------------ index.html ----
i = read("index.html")
if 'id="q-cc"' in i:
    print("• index.html : deja patche, on saute.")
else:
    # 1. exposer l'ouverture du hub qualite (avec cible optionnelle)
    a = "  function open_(){if(!document.getElementById('qa-overlay'))build();show(null);}"
    if a not in i: sys.exit("ERREUR : ancre open_() introuvable dans index.html.")
    b = ("  function open_(u){if(!document.getElementById('qa-overlay'))build();"
         "show(typeof u==='string'?u:null);}\n  window.QA_OPEN=open_;")
    i = i.replace(a, b, 1)

    # 2. boutons dans la barre d'outils de l'onglet Suivi qualite
    a = ("    + '<button class=\"btn btn-ghost btn-sm\" id=\"q-refresh\">Actualiser</button>'\n"
         "    + '<a class=\"btn btn-ghost btn-sm\" href=\"/api/export.csv\">Exporter (CSV)</a></div>'")
    if a not in i: sys.exit("ERREUR : ancre barre d'outils Suivi qualite introuvable.")
    b = ("    + '<button class=\"btn btn-ghost btn-sm\" id=\"q-refresh\">Actualiser</button>'\n"
         "    + '<button class=\"btn btn-ghost btn-sm\" id=\"q-cc\">Change Control (QUAL02)</button>'\n"
         "    + '<button class=\"btn btn-ghost btn-sm\" id=\"q-reg\">Registres qualit\\u00e9</button>'\n"
         "    + '<a class=\"btn btn-ghost btn-sm\" href=\"/api/export.csv\">Exporter (CSV)</a></div>'")
    i = i.replace(a, b, 1)

    # 3. branchement des boutons
    a = '  $("#q-refresh").addEventListener("click", loadList);'
    if a not in i: sys.exit("ERREUR : ancre des ecouteurs Suivi qualite introuvable.")
    b = (a + "\n"
         '  var _cc=$("#q-cc"); if(_cc) _cc.addEventListener("click", function(){ '
         'if(window.QA_OPEN) window.QA_OPEN("/cc"); });\n'
         '  var _rg=$("#q-reg"); if(_rg) _rg.addEventListener("click", function(){ '
         'if(window.QA_OPEN) window.QA_OPEN(); });')
    i = i.replace(a, b, 1)
    write("index.html", i); changed.append("index.html")
    print("✓ index.html : Change Control et registres accessibles depuis Suivi qualite.")

print("Fichiers modifies : " + (", ".join(changed) if changed else "aucun (deja a jour)"))
PYEOF

# --- Controle de compilation (restauration auto si KO) -----------------------
if python3 -c "import ast,io; ast.parse(io.open('cc.py',encoding='utf-8').read())"; then
    echo "✓ cc.py OK."
else
    echo "✗ cc.py NE COMPILE PAS — restauration."
    cp -p "cc.py.$TS.bak" cc.py
    cp -p "cc.html.$TS.bak" cc.html
    cp -p "index.html.$TS.bak" index.html
    echo "Restauration effectuee. Aucun deploiement lance."
    exit 1
fi

echo "== Rebuild Docker =="
docker compose up -d --build

echo
echo "TERMINE."
echo " • Change Control : nouveau champ « Gravite » (mineur / majeur / critique)."
echo " • Onglet Suivi qualite : boutons « Change Control (QUAL02) » et « Registres qualite »."
echo " (Si l'interface ne bouge pas : Ctrl+Maj+R pour vider le cache.)"
