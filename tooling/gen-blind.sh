#!/usr/bin/env bash
set -euo pipefail
# Generate a BLIND app tree from main's HEAD into an output directory, then gate it.
#
#   gen-blind.sh vulnerable [OUT_DIR]   # blind + still vulnerable (scanner target)
#   gen-blind.sh fixed      [OUT_DIR]   # blind + fixed (negative control)
#
# main's app source is written blind: no markers and no notes about the planted instances (those
# live in benchmark/). So the vulnerable tree is main's app files byte for byte, and the manifest's
# line ranges hold for it unchanged. Only main's project front page differs: the blind README is
# tooling/branch-README.md, and the front page's images are dropped.
# Steps: export main's tree -> swap in the branch README, drop the images -> remove benchmark/ tooling/
# .github/ -> (fixed: fix_apply) -> blind_strip --check (any comment clue fails the build: fix it on
# main, never strip it, since a strip would shift the ground-truth lines) -> clue-scan gate.
# Does NOT create/push git branches; it produces a reviewable tree.
# Env: APP_DIR (main checkout, default: this repo).
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${APP_DIR:-$HERE/..}"
KIND="${1:-}"
OUT="${2:-/tmp/legacy-goat-$KIND}"

case "$KIND" in
  vulnerable|fixed) ;;
  *) echo "usage: gen-blind.sh vulnerable|fixed [OUT_DIR]" >&2; exit 2 ;;
esac

rm -rf "$OUT"; mkdir -p "$OUT"
echo "[gen-blind] exporting main tree from $APP_DIR -> $OUT"
git -C "$APP_DIR" archive --format=tar HEAD | tar -x -C "$OUT"

echo "[gen-blind] swapping in the branch README and dropping the front page's images"
mv "$OUT/tooling/branch-README.md" "$OUT/README.md"
rm -f "$OUT/legacy-goat-sm.png" "$OUT/legacy-goat-console.png"

echo "[gen-blind] removing benchmark/ answer key, tooling/ generator, and CI (scan boundary = app source only)"
rm -rf "$OUT/benchmark" "$OUT/tooling" "$OUT/.github"

if [ "$KIND" = "fixed" ]; then
  echo "[gen-blind] applying per-instance fixes"
  python3 "$HERE/fix_apply.py" "$OUT"
fi

echo "[gen-blind] blind_strip check (main must already be blind)"
python3 "$HERE/blind_strip.py" --check "$OUT"

echo "[gen-blind] clue-scan gate"
"$HERE/clue-scan.sh" "$OUT"

echo "[gen-blind] OK: blind '$KIND' tree at $OUT"
