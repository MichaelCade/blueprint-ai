#!/bin/sh
# Runs INSIDE the keeper pod. Exports every SurrealDB namespace/database to the keeper
# PVC, then flushes the filesystem so the CSI snapshot sees the bytes.
#
# The blueprint's backupPrehook carries the same script inline; this copy is what was
# validated by hand in Step 3 and is kept so the two can be compared.
#
# Needs: SURREAL_ENDPOINT, SURREAL_USER, SURREAL_PASS (from the keeper's env).
set -eu

ROOT=/backup
OUT="${ROOT}/surrealdb"                 # the dump Kasten captures
STAGE="${ROOT}/.staging"                # written first, swapped in only when complete
SQL="/surreal sql -e ${SURREAL_ENDPOINT} --hide-welcome --json"

# `surreal sql --json` prints one JSON line per statement. The last non-empty line is the
# answer to the RETURN. Turn ["a","b"] into "a b" without jq (the image has none).
last_list() { grep -v '^$' | tail -1 | sed 's/^\[\[*//; s/\]*\]$//; s/"//g; s/,/ /g'; }

# Refuse anything that is not a plain identifier: a name we cannot quote safely in
# a shell command or a file path is a reason to stop, not to guess.
check_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*) echo "ERROR: unsupported name '$1'"; exit 1 ;;
  esac
}

rm -rf "${STAGE}"
mkdir -p "${STAGE}"

NAMESPACES=$(echo 'RETURN object::keys((INFO FOR ROOT).namespaces);' | ${SQL} | last_list)
[ -n "${NAMESPACES}" ] || { echo "ERROR: no namespace found (authentication or endpoint?)"; exit 1; }

COUNT=0
for NS in ${NAMESPACES}; do
  check_name "${NS}"
  DATABASES=$(printf 'USE NS %s;\nRETURN object::keys((INFO FOR NS).databases);\n' "${NS}" | ${SQL} | last_list)
  for DB in ${DATABASES}; do
    check_name "${DB}"
    mkdir -p "${STAGE}/${NS}"
    FILE="${STAGE}/${NS}/${DB}.surql"
    # One export = one read transaction = one consistent point in time for this database.
    /surreal export -e "${SURREAL_ENDPOINT}" --ns "${NS}" --db "${DB}" "${FILE}"
    [ -s "${FILE}" ] || { echo "ERROR: empty export for ${NS}/${DB}"; exit 1; }
    echo "${NS} ${DB} $(wc -c < "${FILE}") $(sha256sum "${FILE}" | cut -d' ' -f1)" >> "${STAGE}/MANIFEST"
    COUNT=$((COUNT + 1))
  done
done

date -u +%Y-%m-%dT%H:%M:%SZ > "${STAGE}/TIMESTAMP"

# Swap the complete staging directory in. A failed run above leaves the previous dump untouched.
rm -rf "${OUT}.old"
[ -d "${OUT}" ] && mv "${OUT}" "${OUT}.old"
mv "${STAGE}" "${OUT}"
rm -rf "${OUT}.old"

# LAST step: flush to disk. A CSI snapshot copies the block device, not the page cache.
sync

# Re-read every file and compare it with the checksum taken at export time, so a file
# truncated or replaced after the export fails the backup instead of reaching the snapshot.
while read -r NS DB SIZE SUM; do
  [ "$(sha256sum "${OUT}/${NS}/${DB}.surql" | cut -d' ' -f1)" = "${SUM}" ] \
    || { echo "ERROR: ${NS}/${DB} changed after export"; exit 1; }
done < "${OUT}/MANIFEST"

echo "Exported ${COUNT} database(s) at $(cat "${OUT}/TIMESTAMP"):"
cat "${OUT}/MANIFEST"
