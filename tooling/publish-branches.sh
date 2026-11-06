#!/usr/bin/env bash
set -euo pipefail
# Regenerate the blind `vulnerable` and `fixed` branches from legacy-goat main and force-push them as
# orphan (single-commit, reset-history) branches. ATOMIC over the patching step: BOTH trees are
# generated and clue-scan-gated before EITHER branch is pushed, so a patch/gate failure leaves the
# last-known-good branches untouched (the script exits non-zero having pushed nothing).
#
# Env:
#   LG_DIR    legacy-goat checkout at main (default: this repo)
#   REMOTE    git URL to push the blind branches to (default: LG_DIR's origin)
#   DRY_RUN   1 = generate + gate + build the orphan commits but do NOT push (default 0)
#
# The tooling (this script + gen-blind/blind_strip/fix_apply/clue-scan/clues) lives in this repo's
# tooling/, which the generator strips from the blind branches, so those branches stay app-source-only.
HERE="$(cd "$(dirname "$0")" && pwd)"
LG_DIR="${LG_DIR:-$HERE/..}"
REMOTE="${REMOTE:-$(git -C "$LG_DIR" remote get-url origin)}"
DRY_RUN="${DRY_RUN:-0}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SHA="$(git -C "$LG_DIR" rev-parse --short HEAD)"
echo "[publish] source: $LG_DIR @ main $SHA -> $REMOTE (dry_run=$DRY_RUN)"

# 1) Generate + gate BOTH trees first. gen-blind.sh runs clue-scan and exits non-zero on any leak,
#    so `set -e` aborts here (before any push) if either branch fails to build cleanly.
APP_DIR="$LG_DIR" "$HERE/gen-blind.sh" vulnerable "$WORK/vulnerable"
APP_DIR="$LG_DIR" "$HERE/gen-blind.sh" fixed      "$WORK/fixed"

# 2) Build both orphan commits (still no push).
build_orphan() {  # build_orphan <kind> <tree>
  local kind="$1" tree="$2" d="$WORK/git-$1"
  mkdir -p "$d"; cp -a "$tree/." "$d/"
  git -C "$d" init -q -b "$kind"
  git -C "$d" add -A
  # The commit names no other branch and says nothing about what the tree contains.
  git -C "$d" -c user.email="branch-bot@octane.security" -c user.name="branch bot" \
      commit -q -m "Branch to be scanned for issues"
}
build_orphan vulnerable "$WORK/vulnerable"
build_orphan fixed      "$WORK/fixed"

# 3) Push both (back-to-back, after both are validated + committed).
for kind in vulnerable fixed; do
  if [ "$DRY_RUN" = "1" ]; then
    echo "[publish] DRY_RUN: would force-push '$kind' ($(git -C "$WORK/git-$kind" rev-parse --short HEAD)) to $REMOTE"
  else
    git -C "$WORK/git-$kind" push -f "$REMOTE" "$kind"
    echo "[publish] force-pushed '$kind' to $REMOTE"
  fi
done
echo "[publish] done"
