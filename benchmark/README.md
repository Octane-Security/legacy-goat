# benchmark — ground truth

The answer key for the vulnerability-detection benchmark. This tree exists on `main` only. It is
absent from the blind branches (`vulnerable`, `fixed`), which are generated from `main` by
[../tooling/](../tooling/).

The benchmark scores **reachability, not just pattern presence.** A vulnerable pattern being present
is necessary but not sufficient: the ground truth records whether each instance is actually
exploitable under a given profile, and a scanner is scored on getting that verdict right.

## Files

| File | Role |
|---|---|
| [taxonomy.md](taxonomy.md) | the curated CWE-mapped corpus, one row per class |
| `manifest.yaml` | one machine-readable entry per injected instance, incl. per-profile exploitability |
| `recipes/<id>.yaml` | the structured, ordered exploit recipe for each stateful/multi-stage instance |
| `ground-truth.<profile>.sarif` | generated per profile from the manifest; a scorer diffs a scanner's output (run under that profile) against it |

Generated files (`ground-truth.*.sarif`) are never hand-edited: regenerate them with the runtimes
tooling (`make ground-truth`) whenever `manifest.yaml` or a located file changes, then check them
against the tree (`make check-alignment`).

## Exploitability model

Exploitability is a property of an **(instance, profile)** pair, not of the instance alone. The same
`LG-...` instance can be exploitable under one profile and inert under another.

- **Grades** (per profile): `exploitable` (reachable and exploitable) or `unexploitable` (pattern
  present but guarded, unreachable, or dead under this profile).
- **Gates** — what flips a grade:
  - `config` — a config-file/env flag value the app reads (e.g. `session_roaming`, `report_archive`).
  - `data` — a seeded data condition (an account `FROZEN`, a customer `risk_rating=D`, a record's
    existence).
  - `state` — a runtime state only reachable by an ordered multi-step sequence (see recipes).
  A gate may combine these (`config` AND `state`).
- **Present-but-unexploitable** instances are deliberate **hard negatives**: a reachability-aware
  scanner finds the pattern and marks it not-exploitable; a pattern matcher over-reports it.

## Profiles

A profile is a named bundle of **config values + seed-data variant** (plus any feature env),
selected by `APP_PROFILE` in the harness alongside `APP_BRANCH`. The same vulnerable source runs
under each profile; scoring compares the scanner's verdict to that profile's ground truth. Flipping
the profile and re-scoring is how config/data-dependence is tested end to end — a good scanner
changes its exploitability verdict when the gate changes. Profile definitions live operator-side in
`legacy-goat-runtimes` (config + seed variants); this tree records, per instance, its grade under
each profile.

## Structured exploit recipes

Every `exploitable` (instance, profile) carries a machine-readable recipe (`recipes/<id>.yaml`). The
runtimes trigger automates it; the scorer references its `observable`.

```yaml
preconditions: [ "config session_roaming=on", "account 000000000042 state=FROZEN" ]
steps:
  - { call: "POST /session/login", body: {...}, expect: "token issued" }
  - { call: "POST /transfer", body: {...}, expect: "state=PENDING" }
  - { call: "POST /transfer/approve", body: {...}, expect: "state=POSTED, sink reached" }
observable: "the effect that proves exploitation (row read, command output, balance drift, leak)"
```

`state`-gated instances need 2+ ordered steps that move DB/session state so a later sink becomes
reachable; the recipe is that sequence.

## Instance ids and locations

Each instance has a stable id `LG-<CLASS>-<NNN>` that keys its `manifest.yaml` entry, its recipe and
its runtimes trigger. The id appears only here and operator-side: **main's app source carries no
markers.** An instance is located by its manifest `locations` entry: `file`, `lines`, and an `anchor`
(a code fragment that must appear inside `lines`). Everything the source does not say about an
instance (why it is weak, how the trigger works) goes in the entry's `notes`.

## Blind-branch discipline

main's app source is written blind. Identifiers, setting names, string literals, comments and
documents describe the application only: no instance ids, no CWE tokens, no path labels such as
safe/unsafe/vuln/legacy, no notes on what a construct does wrong, and no benchmark vocabulary. So
`vulnerable` is main's app files byte for byte, minus `benchmark/`, `tooling/` and `.github/`, and the
manifest's line ranges hold for it unchanged. `fixed` is the same tree with every instance's fix
applied (`tooling/fix_apply.py`). Both blind branches get a neutral git history. The grades, recipes,
notes and profile-to-grade map are answer-key material and never ship on a blind branch.

The gate (`tooling/clue-scan.sh`, vocabulary in `tooling/clues.py`) fails the build if any clue is on
a blind tree, and `tooling/blind_strip.py --check` fails it if any comment carries one. Before a
publish, a fresh reviewer with no access to `main`, this tree or legacy-goat-runtimes reads the
generated `vulnerable` tree for anything that suggests where a weakness is. Distribute one blind
branch at a time; score against `main`.

## manifest.yaml entry shape

```yaml
- id: LG-SQLI-001              # stable id; never appears in the app source
  cwe: 89
  title: <short title>
  class: sql-injection         # taxonomy class slug
  module: cobol
  language: COBOL
  sink: <the vulnerable construct, one line>
  notes: <what the source does not say: why the construct is weak, what a trigger relies on>
  detection: runtime           # optional; "runtime" (default) or "static" (no reachability/trigger)
  locations:                   # same lines on main and vulnerable (identical app files)
    main: { file: cobol/postxfer.cbl, lines: "120-134", anchor: "<code fragment inside lines>" }
  exploitability:              # per-profile grade + gate
    baseline:   { status: unexploitable, gate: { config: "report_archive=off" } }
    permissive: { status: exploitable,   gate: { config: "report_archive=on" }, recipe: recipes/LG-SQLI-001.yaml }
```

`status` is `exploitable` | `unexploitable` for runtime findings, or `present` for a `detection: static`
finding (a static weakness — e.g. a hardcoded secret — with no runtime reachability path). Static
findings carry no `recipe` and no runtime trigger; the harness records their presence and they are
scored against static ground truth rather than the fire/inert matrix.
