#!/usr/bin/env bash
set -euo pipefail
# Acceptance gate for a BLIND branch tree (vulnerable / fixed): fail if any benchmark clue survives.
#
#   clue-scan.sh <tree_dir>
#
# Scans ALL text in the tree against the vocabulary in clues.py: code identifiers, string literals,
# comments in every language's syntax, documents, JSON schema text, XML and file names. Also fails
# if benchmark/, tooling/ or .github/ is present. One line per hit:
#   CLUE [rule] channel path:line: text
# Exit 0 = clean; 1 = clues found; 2 = bad usage.
#
# Config settings are app configuration, so a setting is never a clue for existing, but setting
# names are held to the same vocabulary as any identifier (no legacy/safe/strict path labels).
HERE="$(cd "$(dirname "$0")" && pwd)"
app_dir="${1:?usage: clue-scan.sh <tree_dir>}"
exec python3 "$HERE/clues.py" "$app_dir"
