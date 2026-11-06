# tooling — blind-branch generator

Generates this repo's blind `vulnerable` / `fixed` branches from `main`. It lives here (not in
legacy-goat-runtimes) so the CI can force-push the branches with the repo's own `GITHUB_TOKEN`, no
cross-repo secret. The generator strips `tooling/`, `benchmark/`, and `.github/` from the blind
branches, so what a scanner receives is app source only — the generator, the answer key, and the CI
never reach a scanned branch.

**main's app source is written blind.** No marker banners and no notes about the planted instances
in app files: identifiers, setting names, comments and documents describe the application only. The
answer key, including every note about an instance, lives in `benchmark/manifest.yaml`. So the
`vulnerable` tree is main's app files byte for byte, and the manifest's line ranges hold for it.
main's project front page is the one exception: the blind branches carry `branch-README.md` as their
README, and neither of its images, since the project's name and description would tell a scanner what
it is reading.

- **clues.py** — the clue vocabulary, the per-language comment lexers and the tree scan, shared by
  the gate and blind_strip. A clue is a marker id (numbered or not), a CWE/CVE reference, weakness or
  path-label vocabulary (safe/unsafe/vuln/legacy, leak, forge, traversal, ...), benchmark vocabulary
  (seam, clean build, gate, profile, ...) or an attack sample, in any text: code, strings, comments,
  documents, JSON schema text, XML, file names. Deliberate exemptions are listed in `EXEMPT_TOKENS`,
  and `EXEMPT_FILES` skips the GPL `LICENSE` while its text is the verbatim license.
- **clue-scan.sh** — acceptance gate: `clue-scan.sh <tree>` fails on any clue or on a
  `benchmark/`, `tooling/` or `.github/` tree.
- **blind_strip.py** — the backstop for comments: removes any comment block carrying a clue, whole,
  in every comment syntax; reports clues it cannot remove (code, strings, documents). gen-blind runs
  it with `--check` and fails on any finding, since a strip would shift the ground-truth lines.
- **fix_apply.py** — apply the 16 per-instance fixes (remove the exploitable construct, keep the
  other setting's behavior per the manifest `fix:` notes). Missing/duplicate anchor = hard error.
- **gen-blind.sh** — `gen-blind.sh vulnerable|fixed OUT`: git archive main → swap in
  `branch-README.md` and drop the images → strip benchmark//tooling//.github/ → (fixed: fix_apply) →
  blind_strip --check → clue-scan gate. Emits a reviewable directory.
- **publish-branches.sh** — regenerate BOTH trees, gate both, then force-push them as orphan
  (reset-history) branches. ATOMIC over patching: nothing is pushed unless both build + gate cleanly,
  so a failure leaves the last-known-good branches untouched. `DRY_RUN=1` builds the orphan commits
  without pushing.
- **test_gate.py** — regression test: the gate must fail on two recorded leaky trees and report
  every recorded leak; blind_strip must strip every comment syntax whole without touching code; both
  generated trees must pass the gate, with `vulnerable` byte-identical to main's app files; an edited
  `LICENSE` must lose its exemption.

CI: `.github/workflows/publish-blind-branches.yml` runs `test_gate.py`, then `publish-branches.sh`, on
every push to main, force-pushing `vulnerable`/`fixed` to this repo with `GITHUB_TOKEN`
(`permissions: contents: write`). No secret.

A second, independent gate runs before publishing by hand: give the generated `vulnerable` tree to a
fresh reviewer with no access to `main`, `benchmark/` or legacy-goat-runtimes, and ask for any text
that suggests where a weakness is or what it does.

Scoring the branches (ground-truth SARIF, alignment check, scorer) lives operator-side in
`legacy-goat-runtimes/tooling/`.
