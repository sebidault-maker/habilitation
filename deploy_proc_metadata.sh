#!/usr/bin/env bash
# =====================================================================
#  deploy_proc_metadata.sh
#  Etape 2 procedures : ajoute redacteur / verificateur / approbateur (RQ)
#  et date d'application au modele, au formulaire d'ajout, a un formulaire
#  d'edition (bouton "Editer") et a l'affichage des listes.
#
#  - Patche app.py (migration additive + API) et index.html (UI).
#  - Defauts sur les fiches existantes : S. Bidault / C. Verdon / S. Rabussier.
#    (date d'application laissee vide => "date manquante", a renseigner par fiche).
#  - Sauvegardes .bak horodatees, compile-check app.py avec restauration auto,
#    idempotent (2e passage neutre), ne touche jamais .env ni la base.
# =====================================================================
set -euo pipefail

APPDIR="${APPDIR:-/opt/registre-gmp}"
cd "$APPDIR"

for f in app.py index.html; do
  if [ ! -f "$f" ]; then
    echo "ERREUR : $f introuvable dans $APPDIR — abandon." >&2
    exit 1
  fi
done

# ---- patcher Python embarque -----------------------------------------
cat > _patch_proc.py <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, shutil, datetime, py_compile
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

APP_MARK = "ADD COLUMN redacteur"
APP = [
 ('    # Seed des 3 plannings de production (une seule fois). Ampoule en premier.',
  '''    # Maitrise documentaire des procedures : redacteur / verificateur / approbateur (RQ) / date.
    cols_proc = {r["name"] for r in con.execute("PRAGMA table_info(procedures)")}
    _proc_added = False
    if "redacteur" not in cols_proc:
        con.execute("ALTER TABLE procedures ADD COLUMN redacteur TEXT DEFAULT ''"); _proc_added = True
    if "verificateur" not in cols_proc:
        con.execute("ALTER TABLE procedures ADD COLUMN verificateur TEXT DEFAULT ''"); _proc_added = True
    if "approbateur" not in cols_proc:
        con.execute("ALTER TABLE procedures ADD COLUMN approbateur TEXT DEFAULT ''"); _proc_added = True
    if "date_application" not in cols_proc:
        con.execute("ALTER TABLE procedures ADD COLUMN date_application TEXT DEFAULT ''")
    if _proc_added:
        con.execute("UPDATE procedures SET redacteur='S. Bidault' WHERE redacteur IS NULL OR redacteur=''")
        con.execute("UPDATE procedures SET verificateur='C. Verdon' WHERE verificateur IS NULL OR verificateur=''")
        con.execute("UPDATE procedures SET approbateur='S. Rabussier' WHERE approbateur IS NULL OR approbateur=''")
    # Seed des 3 plannings de production (une seule fois). Ampoule en premier.'''),

 ('''            "active": bool(r["active"]), "uploadedAt": r["uploaded_at"],
            "uploadedBy": r["uploaded_by"] or ""}''',
  '''            "active": bool(r["active"]), "uploadedAt": r["uploaded_at"],
            "uploadedBy": r["uploaded_by"] or "",
            "redacteur": (r["redacteur"] if "redacteur" in r.keys() else "") or "",
            "verificateur": (r["verificateur"] if "verificateur" in r.keys() else "") or "",
            "approbateur": (r["approbateur"] if "approbateur" in r.keys() else "") or "",
            "dateApplication": (r["date_application"] if "date_application" in r.keys() else "") or ""}'''),

 ('''    category = (request.form.get("category") or "").strip()
    version = (request.form.get("version") or "").strip()
    stored = secrets.token_hex(8) + ("." + ext if ext else "")
    f.save(os.path.join(PROC_DIR, stored))
    size = os.path.getsize(os.path.join(PROC_DIR, stored))
    con = db()
    cur = con.execute(
        "INSERT INTO procedures(code,title,category,version,filename,orig_name,mime,size,active,uploaded_at,uploaded_by) "
        "VALUES(?,?,?,?,?,?,?,?,1,?,?)",
        (code, title, category, version, stored, orig, f.mimetype or "", size, now_iso(), session.get("name", "")))''',
  '''    category = (request.form.get("category") or "").strip()
    version = (request.form.get("version") or "").strip()
    redacteur = (request.form.get("redacteur") or "S. Bidault").strip()
    verificateur = (request.form.get("verificateur") or "C. Verdon").strip()
    approbateur = (request.form.get("approbateur") or "S. Rabussier").strip()
    date_application = (request.form.get("dateApplication") or request.form.get("date_application") or "").strip()
    stored = secrets.token_hex(8) + ("." + ext if ext else "")
    f.save(os.path.join(PROC_DIR, stored))
    size = os.path.getsize(os.path.join(PROC_DIR, stored))
    con = db()
    cur = con.execute(
        "INSERT INTO procedures(code,title,category,version,filename,orig_name,mime,size,active,uploaded_at,uploaded_by,redacteur,verificateur,approbateur,date_application) "
        "VALUES(?,?,?,?,?,?,?,?,1,?,?,?,?,?,?)",
        (code, title, category, version, stored, orig, f.mimetype or "", size, now_iso(), session.get("name", ""), redacteur, verificateur, approbateur, date_application))'''),

 ('''    code = (g("code", r["code"]) or "").strip()
    title = (g("title", r["title"]) or "").strip()
    category = (g("category", r["category"]) or "").strip()
    version = (g("version", r["version"]) or "").strip()
    av = form.get("active")
    active = r["active"] if av is None else (1 if str(av).lower() in ("1", "true", "on", "yes") else 0)
    con.execute("UPDATE procedures SET code=?, title=?, category=?, version=?, active=? WHERE id=?",
                (code, title, category, version, active, pid))''',
  '''    code = (g("code", r["code"]) or "").strip()
    title = (g("title", r["title"]) or "").strip()
    category = (g("category", r["category"]) or "").strip()
    version = (g("version", r["version"]) or "").strip()
    redacteur = (g("redacteur", (r["redacteur"] if "redacteur" in r.keys() else "")) or "").strip()
    verificateur = (g("verificateur", (r["verificateur"] if "verificateur" in r.keys() else "")) or "").strip()
    approbateur = (g("approbateur", (r["approbateur"] if "approbateur" in r.keys() else "")) or "").strip()
    date_application = (g("dateApplication", g("date_application", (r["date_application"] if "date_application" in r.keys() else ""))) or "").strip()
    av = form.get("active")
    active = r["active"] if av is None else (1 if str(av).lower() in ("1", "true", "on", "yes") else 0)
    con.execute("UPDATE procedures SET code=?, title=?, category=?, version=?, active=?, redacteur=?, verificateur=?, approbateur=?, date_application=? WHERE id=?",
                (code, title, category, version, active, redacteur, verificateur, approbateur, date_application, pid))'''),
]

IDX_MARK = "function editProc("
IDX = [
 ("""    + '<div style="flex:0 0 120px"><label>Version</label><input type="text" id="np-ver" placeholder="v1.0"></div></div>'
    + '<label>Fichier (PDF, Word, Excel, image\u2026)</label>""",
  """    + '<div style="flex:0 0 120px"><label>Version</label><input type="text" id="np-ver" placeholder="v1.0"></div></div>'
    + '<div class="row"><div><label>R&eacute;daction</label><input type="text" id="np-red" value="S. Bidault"></div>'
    + '<div><label>V&eacute;rification</label><input type="text" id="np-verif" value="C. Verdon"></div>'
    + '<div><label>Approbation (RQ)</label><input type="text" id="np-app" value="S. Rabussier"></div></div>'
    + '<div class="row"><div style="flex:0 0 200px"><label>Date d&rsquo;application</label><input type="date" id="np-date"></div></div>'
    + '<label>Fichier (PDF, Word, Excel, image\u2026)</label>"""),

 ('''  fd.append("category",$("#np-cat").value.trim()); fd.append("version",$("#np-ver").value.trim());
  fd.append("file",file);''',
  '''  fd.append("category",$("#np-cat").value.trim()); fd.append("version",$("#np-ver").value.trim());
  fd.append("redacteur",$("#np-red").value.trim()); fd.append("verificateur",$("#np-verif").value.trim());
  fd.append("approbateur",$("#np-app").value.trim()); fd.append("dateApplication",$("#np-date").value.trim());
  fd.append("file",file);'''),

 ("""fmtSize(r.size):'')+'</span></td>'""",
  """fmtSize(r.size):'')+'</span><br><span class="muted" style="font-size:.85em">R&eacute;d. '+esc(r.redacteur||"-")+' &middot; V&eacute;rif. '+esc(r.verificateur||"-")+' &middot; Appr. '+esc(r.approbateur||"-")+(r.dateApplication?' &middot; Application : '+esc(r.dateApplication):' &middot; <span style="color:var(--red)">date manquante</span>')+'</span></td>'"""),

 ('''<button class="btn btn-ghost btn-sm" data-pview="'+r.id+'">Lire</button> ''',
  '''<button class="btn btn-ghost btn-sm" data-pview="'+r.id+'">Lire</button> <button class="btn btn-ghost btn-sm" data-pedit="'+r.id+'">\u00c9diter</button> '''),

 ('''  box.querySelectorAll("[data-pdel]").forEach(b => b.addEventListener("click", async () => {
    if(!confirm("Supprimer d\u00e9finitivement cette proc\u00e9dure ?")) return;
    try{ await api("/api/procedures/"+b.dataset.pdel,{method:"DELETE"}); procManage(); }catch(e){ alert(e.message); }
  }));
}''',
  '''  box.querySelectorAll("[data-pdel]").forEach(b => b.addEventListener("click", async () => {
    if(!confirm("Supprimer d\u00e9finitivement cette proc\u00e9dure ?")) return;
    try{ await api("/api/procedures/"+b.dataset.pdel,{method:"DELETE"}); procManage(); }catch(e){ alert(e.message); }
  }));
  box.querySelectorAll("[data-pedit]").forEach(b => b.addEventListener("click", () => {
    const r = rows.find(x => String(x.id)===b.dataset.pedit); if(r) editProc(r);
  }));
}
function editProc(r){
  $("#sheet").innerHTML =
    '<h3>M&eacute;tadonn&eacute;es \u2014 '+esc(r.code)+'</h3>'
    + '<div class="row"><div style="flex:0 0 140px"><label>Code</label><input type="text" id="ep-code" value="'+esc(r.code)+'"></div>'
    + '<div><label>Intitul&eacute;</label><input type="text" id="ep-title" value="'+esc(r.title)+'"></div></div>'
    + '<div class="row"><div><label>Cat&eacute;gorie</label><input type="text" id="ep-cat" value="'+esc(r.category||"")+'"></div>'
    + '<div style="flex:0 0 120px"><label>Version</label><input type="text" id="ep-ver" value="'+esc(r.version||"")+'"></div></div>'
    + '<div class="row"><div><label>R&eacute;daction</label><input type="text" id="ep-red" value="'+esc(r.redacteur||"")+'"></div>'
    + '<div><label>V&eacute;rification</label><input type="text" id="ep-verif" value="'+esc(r.verificateur||"")+'"></div>'
    + '<div><label>Approbation (RQ)</label><input type="text" id="ep-app" value="'+esc(r.approbateur||"")+'"></div></div>'
    + '<div class="row"><div style="flex:0 0 200px"><label>Date d&rsquo;application</label><input type="date" id="ep-date" value="'+esc(r.dateApplication||"")+'"></div></div>'
    + '<div id="ep-fb"></div>'
    + '<div class="btn-row"><button class="btn btn-primary" id="ep-save">Enregistrer</button><button class="btn btn-ghost" id="ep-close">Fermer</button></div>';
  $("#overlay").classList.add("on");
  $("#ep-close").addEventListener("click", closeReader);
  $("#ep-save").addEventListener("click", async () => {
    const body={code:$("#ep-code").value.trim(),title:$("#ep-title").value.trim(),category:$("#ep-cat").value.trim(),version:$("#ep-ver").value.trim(),redacteur:$("#ep-red").value.trim(),verificateur:$("#ep-verif").value.trim(),approbateur:$("#ep-app").value.trim(),dateApplication:$("#ep-date").value.trim()};
    try{ await api("/api/procedures/"+r.id,{method:"PUT",body:JSON.stringify(body)}); closeReader(); procManage(); }
    catch(e){ $("#ep-fb").innerHTML='<div class="err">'+esc(e.message)+'</div>'; }
  });
}'''),

 ("""fmtSize(r.size):'')+'</span></div>'""",
  """fmtSize(r.size):'')+'</span><br><span class="muted" style="font-size:.85em">R&eacute;d. '+esc(r.redacteur||"-")+' &middot; V&eacute;rif. '+esc(r.verificateur||"-")+' &middot; Appr. '+esc(r.approbateur||"-")+(r.dateApplication?' &middot; Application : '+esc(r.dateApplication):'')+'</span></div>'"""),
]


def apply(path, repls, mark, compile_check=False):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if mark in src:
        print("  %-12s : deja patche - ignore." % path); return
    for old, new in repls:
        n = src.count(old)
        if n != 1:
            print("  ERREUR %s : motif %d fois (attendu 1) :\n    %r" % (path, n, old[:80])); sys.exit(2)
        src = src.replace(old, new, 1)
    bak = "%s.%s.bak" % (path, STAMP)
    shutil.copy2(path, bak)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    if compile_check:
        try:
            py_compile.compile(path, doraise=True)
        except py_compile.PyCompileError as e:
            shutil.copy2(bak, path)
            print("  ERREUR compilation %s - restaure.\n%s" % (path, e)); sys.exit(3)
    print("  %-12s : patche OK (sauvegarde %s)" % (path, os.path.basename(bak)))


print("Etape 2 procedures (4 champs maitrise documentaire) :")
apply("app.py", APP, APP_MARK, compile_check=True)
apply("index.html", IDX, IDX_MARK)
print("Termine.")
PYEOF

# ---- execution du patcher --------------------------------------------
echo "=== Application du patch procedures ==="
if ! python3 _patch_proc.py; then
  echo "ERREUR : le patch a echoue — aucun rebuild lance. Les fichiers d'origine sont intacts (.bak)." >&2
  exit 4
fi

# ---- reconstruction du conteneur -------------------------------------
echo
echo "=== Reconstruction du conteneur (docker compose up -d --build) ==="
docker compose up -d --build

echo
echo "=== Termine ==="
echo "Champs ajoutes : redacteur / verificateur / approbateur (RQ) / date d'application."
echo "Fiches existantes : defauts S. Bidault / C. Verdon / S. Rabussier appliques."
echo "Date d'application : vide au depart (\"date manquante\") — a renseigner via le bouton Editer."
echo "Rafraichis la page (Ctrl+Maj+R) puis va dans Procedures > Gerer."
