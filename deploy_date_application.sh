#!/usr/bin/env bash
# =====================================================================
#  deploy_date_application.sh
#  Renseigne la "date d'application" des procedures (defaut 26/05/2026,
#  stockee en ISO 2026-05-26 pour rester compatible avec le formulaire
#  d'edition type=date).
#
#  - Par defaut : ne remplit QUE les fiches sans date (ne remplace rien).
#  - FORCE=1 : ecrase la date de TOUTES les fiches.
#  - DATE_APP=AAAA-MM-JJ : change la date appliquee.
#  - Sauvegarde la base AVANT. Aucun rebuild. Ne touche pas .env.
#  - Necessite que deploy_proc_metadata.sh soit deja passe (colonne date).
# =====================================================================
set -euo pipefail

APPDIR="${APPDIR:-/opt/registre-gmp}"
CONTAINER="${CONTAINER:-registre-deviations}"
DATE_APP="${DATE_APP:-2026-05-26}"
FORCE="${FORCE:-0}"
cd "$APPDIR"

command -v docker >/dev/null 2>&1 || { echo "ERREUR : docker introuvable." >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "ERREUR : conteneur $CONTAINER non demarre." >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/_set_date.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, sqlite3
DATA = os.environ.get("DATA_DIR", "/app/data")
DB   = os.path.join(DATA, "registre.db")
DATE = os.environ.get("DATE_APP", "2026-05-26")
FORCE = os.environ.get("FORCE", "0") == "1"
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
cols = {r["name"] for r in con.execute("PRAGMA table_info(procedures)")}
if "date_application" not in cols:
    print("ERREUR : colonne 'date_application' absente. Deploie d'abord deploy_proc_metadata.sh.")
    sys.exit(2)
if FORCE:
    cur = con.execute("UPDATE procedures SET date_application=?", (DATE,))
else:
    cur = con.execute("UPDATE procedures SET date_application=? "
                      "WHERE date_application IS NULL OR date_application=''", (DATE,))
con.commit()
n = cur.rowcount
tot = con.execute("SELECT COUNT(*) c FROM procedures").fetchone()["c"]
avec = con.execute("SELECT COUNT(*) c FROM procedures WHERE date_application=?", (DATE,)).fetchone()["c"]
con.close()
print("Date '%s' appliquee a %d fiche(s)%s." % (DATE, n, " (FORCE)" if FORCE else " sans date"))
print("Total fiches : %d | portant cette date : %d" % (tot, avec))
PYEOF
chmod 644 "$TMP/_set_date.py"

echo "=== Sauvegarde de la base (avant) ==="
docker cp "$CONTAINER:/app/data/registre.db" "$APPDIR/registre.db.$STAMP.bak"
echo "  -> $APPDIR/registre.db.$STAMP.bak"

echo "=== Application de la date ($DATE_APP, FORCE=$FORCE) ==="
docker exec "$CONTAINER" rm -f /app/data/_set_date.py 2>/dev/null || true
docker cp "$TMP/_set_date.py" "$CONTAINER:/app/data/_set_date.py"
set +e
docker exec -e DATE_APP="$DATE_APP" -e FORCE="$FORCE" "$CONTAINER" python3 /app/data/_set_date.py
rc=$?
set -e
docker exec "$CONTAINER" rm -f /app/data/_set_date.py || true

echo
if [ "$rc" -ne 0 ]; then
  echo "ATTENTION : code retour $rc (voir message ci-dessus)." >&2
  exit "$rc"
fi
echo "=== Termine ==="
echo "Aucun redemarrage necessaire. Rafraichis la page (Ctrl+Maj+R)."
echo "Rollback eventuel :"
echo "  docker cp \"$APPDIR/registre.db.$STAMP.bak\" $CONTAINER:/app/data/registre.db && docker restart $CONTAINER"
