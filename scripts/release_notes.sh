#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
changes_only=false
[[ "${1:-}" == --changes ]] && { changes_only=true; shift; }
version=${1:?Usage: scripts/release_notes.sh [--changes] MAJOR.MINOR.PATCH}
notes=$(awk -v version="$version" '
  /^## / {
    if (found) exit
    if ($2 == version && $3 == "-") found = 1
    next
  }
  found { print }
  END { if (!found) exit 1 }
' CHANGELOG.md) || { echo "Missing changelog entry for $version" >&2; exit 1; }
if $changes_only; then
  printf '%s\n' "$notes"
  exit
fi
printf '## What changed\n%s\n\n' "$notes"
cat .github/RELEASE_NOTES.md
