#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF2'
Usage: scripts/storage/record-snapshot.sh <name>

Records the storage snapshot for a release. Runs the recordSnapshot test, which builds a
database migrated to the latest migration and fills it with fixture rows, then writes its
sqlite3 .dump to OpenVocallyKit/Tests/StorageTests/Snapshots/<name>.sql.

<name> must be the identifier of the newest migration in AppDatabase.migrator, such as v1.
Commit the file. A shipped snapshot is never re-recorded.
EOF2
}

if [[ $# -ne 1 || "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  [[ $# -eq 1 && ("$1" == "--help" || "$1" == "-h") ]] && exit 0
  exit 1
fi

name="$1"
cd "$(dirname "$0")/../.."
out="OpenVocallyKit/Tests/StorageTests/Snapshots/$name.sql"
if [[ -e "$out" ]]; then
  echo "$out exists. Shipped snapshots are never re-recorded." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
db="$work/snapshot.sqlite"

scripts/whisper/build-xcframework.sh
STORAGE_RECORD_SNAPSHOT="$db" swift test --package-path OpenVocallyKit --filter 'SnapshotMigrationTests/recordSnapshot'
[[ -s "$db" ]] || { echo "The test did not write $db." >&2; exit 1; }
sqlite3 "$db" .dump >"$out"
echo "Wrote $out"
