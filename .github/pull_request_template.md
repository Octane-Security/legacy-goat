<!--
Thanks for contributing. Fill in every section; delete the checklists that don't apply to your type
of change. A checked box needs its evidence below it: the command, the commit it ran against, and
the summary lines of its output. See the Contributing section of the README.
-->

## Linked issue

Closes #

## Type of change

- [ ] Fix for a defect the answer key doesn't list
- [ ] New planted flaw
- [ ] Answer key correction
- [ ] Tooling, branch generation or documentation

## What changed and why

<!-- The change in plain words, and why it is the right fix. -->

## Companion pull request in legacy-goat-runtimes

<!-- Link it, or say why none is needed. A fix needs a regression test there; a new flaw needs its trigger there. -->

## Evidence

<!-- For each check below: the command, the commits of both repositories, and the summary lines of the output. -->

```text

```

## Every pull request

- [ ] It links an issue (trivial fixes such as typos excepted).
- [ ] The application source stays blind: no instance ids, CWE or CVE tokens, path labels, attack samples or notes on what a construct does wrong, in any name, string, comment, document or file name. Any new setting is named after its feature.
- [ ] `python3 tooling/test_gate.py` passes.
- [ ] `tooling/gen-blind.sh vulnerable <dir>` and `tooling/gen-blind.sh fixed <dir>` build, and both trees pass `tooling/clue-scan.sh`.
- [ ] In legacy-goat-runtimes, `make verify APP_PROFILE=baseline` and `make verify APP_PROFILE=permissive` pass with `APP_SRC` set to each generated tree: triggers fire exactly where the answer key grades their instance exploitable on `vulnerable`, and stay inert on `fixed`.
- [ ] `make check-alignment` passes against `main` and against the generated `vulnerable` tree. If a located file's lines moved, the manifest's `lines` and the ground truth (`make ground-truth`) are updated here.
- [ ] It changes only what it needs to. If it touches a planted instance's construct, manifest entry or trigger, the description says why.
- [ ] I offer this contribution under the GNU GPL, version 3. It contains no secrets or personal data, and any image is stripped of metadata.

## Fix for a defect the answer key doesn't list

- [ ] The fix is in the application source on `main`, so it reaches both blind branches.
- [ ] No planted instance's construct changes.
- [ ] The companion pull request adds a regression test to legacy-goat-runtimes `test/` that fails against current `main` and passes against this branch (show both runs).

## New planted flaw

- [ ] Manifest entry with `id`, `cwe`, `class`, `module`, `language`, `sink`, `notes`, `locations.main` (`file`, `lines`, `anchor`), `fix` and per-profile `exploitability` with its `gate`.
- [ ] A recipe in `benchmark/recipes/` for every profile under which it is exploitable.
- [ ] A fix in `tooling/fix_apply.py`. The generated `fixed` tree is inert under both profiles.
- [ ] A trigger in legacy-goat-runtimes `triggers/` that fires only where the instance is graded exploitable, and tries the known ways around a weak guard.
- [ ] A row in legacy-goat-runtimes `docs/attacker-position.md`, and in `benchmark/taxonomy.md` if the class is new.
- [ ] Any new setting has its values in both legacy-goat-runtimes profiles.

## Answer key correction

- [ ] The evidence shows harness output under each affected profile, or a code reference on `main`.
- [ ] The ground truth is regenerated.
