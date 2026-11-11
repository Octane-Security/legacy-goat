# Contributing to Legacy Goat

Legacy Goat is two repositories, and this guide covers both. Most contributions touch both of them.

| Repository | What lives there |
|---|---|
| [legacy-goat](https://github.com/Octane-Security/legacy-goat) | The application source (COBOL, Fortran, Object Pascal, SAS, ABAP), its contracts, the answer key in `benchmark/`, and the tooling that builds the blind `vulnerable` and `fixed` branches |
| [legacy-goat-runtimes](https://github.com/Octane-Security/legacy-goat-runtimes) | The runtime image for each language, the adapters and gateway that put each module behind REST, the databases, the test suites, and one exploit proof (trigger) per planted flaw |

Octane Security maintains both, and we welcome issues and pull requests from the security community.
New flaws, new languages and banking features, sharper exploit proofs, and fixes to anything broken
all make Legacy Goat a better benchmark. If you find a flaw we did not plant, tell us: we either fix
it or add it to the answer key.

## Ground rules

- **Lab only.** Run the stack on your own machine. Its services speak plain HTTP and publish every
  port with throwaway credentials. Don't point anything in these repositories at systems you don't own.
- **Keep the application blind.** Scanners are pointed at the `vulnerable` and `fixed` branches,
  which CI builds from `main`. Nothing in the application source may hint at a flaw: no instance
  ids, CWE or CVE tokens, path labels, attack samples, or comments about what a construct does wrong,
  in any name, string, comment, document or file name. Name a new setting after the feature it
  controls, not after the flaw it gates. `benchmark/` holds everything that describes a flaw, and it
  never reaches the blind branches.
- **License.** Contributions are accepted under the GNU General Public License, version 3. Don't
  include secrets or personal data, and strip metadata from images.

## Start with an issue

Open an issue before you build anything bigger than a typo fix. Each repository has issue forms:

- legacy-goat: **Defect in the application**, **New planted flaw**, **Answer key correction**, and
  **Tooling, branch generation or documentation**.
- legacy-goat-runtimes: **Problem with the harness** and **Exploit proof**.

Propose a new flaw in an issue first, so we can agree on the gate, the profiles and the attacker
position before you write the code.

## Set up

Clone both repositories side by side. You need Docker with Compose, or Podman with `podman compose`,
and [uv](https://docs.astral.sh/uv/), which runs the tests and exploit proofs with their pinned
Python dependencies.

```sh
git clone https://github.com/Octane-Security/legacy-goat.git
git clone https://github.com/Octane-Security/legacy-goat-runtimes.git
cd legacy-goat-runtimes
make up-build APP_PROFILE=permissive   # builds the images; the COBOL one takes a while
make verify APP_PROFILE=permissive     # the suites, then every exploit proof against the answer key
```

The stack mounts `../legacy-goat` and compiles it as the containers start. `APP_SRC=<path>` deploys
any other checkout or a generated blind tree instead. Two profiles exist: `baseline` turns the
gating settings off, and `permissive` turns them on.
[docs/exercising-the-app.md](https://github.com/Octane-Security/legacy-goat-runtimes/blob/main/docs/exercising-the-app.md)
walks through the console and the REST API.

## What each kind of change needs

### Fix a defect the answer key doesn't list

- **legacy-goat:** the fix, in the application source on `main`, without changing any planted
  instance's construct.
- **legacy-goat-runtimes:** a regression test under `test/` that fails on current `main` and passes
  with the fix. It sends legitimate or malformed input and checks documented behavior; it is not an
  exploit.

### Add a planted flaw

- **legacy-goat:**
  - the vulnerable code, blind;
  - an entry in `benchmark/manifest.yaml` with its location, grades per profile and gate
    ([benchmark/README.md](https://github.com/Octane-Security/legacy-goat/blob/main/benchmark/README.md)
    gives the shape);
  - a recipe in `benchmark/recipes/` for every profile under which it is exploitable;
  - its fix in `tooling/fix_apply.py`;
  - the regenerated ground truth.
- **legacy-goat-runtimes:**
  - a trigger, `triggers/<id>.py`, whose `fire()` succeeds only where the instance is graded
    exploitable and tries the known ways around a weak guard;
  - a row in `docs/attacker-position.md`;
  - the values of any new setting in both profiles.

### Correct the answer key

- **legacy-goat:** the corrected entry, the regenerated ground truth, and the evidence: harness
  output under each affected profile, or a code reference on `main`.

### Add a language or a component

A new module, such as a PL/I or RPG service, or a new feature in an existing language, spans both
repositories:

- **legacy-goat:** the module source in its own directory, its REST contract in `contracts/rest/`,
  any record layouts or copybooks it shares, and the layout list in the README.
- **legacy-goat-runtimes:** a runtime image in `runtimes/<lang>/`, an adapter in
  `middleware/adapters/<lang>/` that puts the module behind REST, the compose service, the gateway
  wiring if the flow calls it, and tests that exercise it.

Open an issue first: a new language is a large change, and we will help plan the contracts and the
build.

### Change an exploit proof or the harness

- **legacy-goat-runtimes:** the change, with the fire and inert verdicts unchanged under both
  profiles and on both trees. If a guard gets stronger, its guard-strength check does too. Update
  the README, `docs/attacker-position.md` or `docs/exercising-the-app.md` when behavior changes.

## Checks before you open a pull request

In legacy-goat:

```sh
python3 tooling/test_gate.py
tooling/gen-blind.sh vulnerable <dir>   # each runs the clue-scan gate on the tree it builds
tooling/gen-blind.sh fixed <dir>
```

In legacy-goat-runtimes, with the stack deploying the generated trees:

```sh
make verify APP_PROFILE=baseline   APP_SRC=<dir>/vulnerable   # every trigger matches its grade
make verify APP_PROFILE=permissive APP_SRC=<dir>/vulnerable
make run-integration APP_PROFILE=baseline APP_SRC=<dir>/fixed && make triggers   # nothing fires
make run-integration APP_PROFILE=permissive APP_SRC=<dir>/fixed && make triggers
make check-alignment                      # the answer key still points at its constructs on main
make check-alignment TREE=<dir>/vulnerable
```

`APP_SRC` must be a path the container runtime can mount; on macOS with Podman, keep it under your
home directory.

## Pull requests

Open pull requests against `main` in each repository. When a change spans both, open one in each and
link them to each other. The pull request templates list the checks for each kind of change. Tick a
box only with its evidence below it: the command, the commits of both repositories, and the summary
lines of the output.

Maintainers review the code, the blind-source rules and the harness evidence. Whether any particular
scanner finds a contributed flaw is not part of the review. Legacy Goat measures scanners; it doesn't
favor one.
