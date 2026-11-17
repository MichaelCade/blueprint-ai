#!/bin/sh
# Runs INSIDE the keeper pod, after Kasten has restored the PVCs. Replaces every database
# listed in the dump's MANIFEST with the content of its dump.
#
# The blueprint's restorePosthook carries the same script inline; this copy is what was
# validated by hand in Step 3 and is kept so the two can be compared.
#
# Each database is REMOVED and then imported. An import into an existing database would
# keep records created after the backup, and would fail on DEFINE statements that already
# exist. Databases that are NOT in the dump are left alone. The database is then defined
# with IF NOT EXISTS, because SurrealDB 3 re-creates its default database (`main`) as soon
# as it is removed.
#
# Needs: SURREAL_ENDPOINT, SURREAL_USER, SURREAL_PASS (from the keeper's env).
set -eu

OUT=/backup/surrealdb
SQL="/surreal sql -e ${SURREAL_ENDPOINT} --hide-welcome --json"

[ -s "${OUT}/MANIFEST" ] || { echo "ERROR: no dump in ${OUT} (was the keeper PVC restored?)"; exit 1; }
echo "Restoring the dump taken at $(cat "${OUT}/TIMESTAMP")"

# SurrealDB may still be starting on its restored volume.
i=0
until /surreal isready -e "${SURREAL_ENDPOINT}" >/dev/null 2>&1; do
  i=$((i + 1)); [ "${i}" -le 60 ] || { echo "ERROR: SurrealDB not ready after 5 minutes"; exit 1; }
  sleep 5
done

# `surreal sql` exits 0 even when a statement fails; the failure is a JSON string
# (["..."]) where a success is [null]. Treat any string result as an error.
run_sql() {
  RESULT=$(printf '%b' "$1" | ${SQL} 2>&1)
  if echo "${RESULT}" | grep -q '^\["'; then
    echo "ERROR: ${RESULT}"; exit 1
  fi
}

# Check every file before touching the database: a bad dump must not cost us the live data.
while read -r NS DB SIZE SUM; do
  [ "$(sha256sum "${OUT}/${NS}/${DB}.surql" | cut -d' ' -f1)" = "${SUM}" ] \
    || { echo "ERROR: checksum mismatch for ${NS}/${DB}, nothing restored"; exit 1; }
done < "${OUT}/MANIFEST"

while read -r NS DB SIZE SUM; do
  echo "== ${NS}/${DB} (${SIZE} bytes)"
  run_sql "DEFINE NAMESPACE IF NOT EXISTS ${NS};\nUSE NS ${NS};\nREMOVE DATABASE IF EXISTS ${DB};\nDEFINE DATABASE IF NOT EXISTS ${DB};\n"
  /surreal import -e "${SURREAL_ENDPOINT}" --ns "${NS}" --db "${DB}" "${OUT}/${NS}/${DB}.surql"
done < "${OUT}/MANIFEST"

echo "Restore complete"
