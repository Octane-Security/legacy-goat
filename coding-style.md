# coding-style

Per-language conventions for the application source: terse one-line comments, names that carry the
meaning, and the rules below for the five language dialects and how they bind to
[contracts/](contracts/).

## Syntax

### COBOL (GnuCOBOL 3.2, fixed format)
- Fixed reference format: sequence area 1–6, indicator 7, area A 8–11, area B 12–72.
- Comments are `*>` inline; keep them to one line.
- Keywords and reserved words upper-case; data names upper-case, hyphen-separated.
- `PROGRAM-ID` matches the file stem, upper-case (`POSTXFER` in `postxfer.cbl`).
- Record layouts are never redeclared in a program — `COPY` the copybook from
  `contracts/copybook/`. The copybook is the source of truth.
- Embedded SQL is `EXEC SQL … END-EXEC` (GixSQL precompile); host variables come from the copybook.

### Fortran (gfortran, free form)
- Free-form `.f90`; `implicit none` in every program unit.
- Lower-case keywords and intrinsics; `snake_case` locals.
- Shared-library entry points use `bind(C)`; fixed-record IO uses explicit `FORMAT` matching
  `contracts/records/fortran-fee-io.md`.

### Object Pascal (Free Pascal 3.2.2, `{$MODE DELPHI}`)
- `{$MODE DELPHI}` at the top of every unit; headless only (fcl-web, no Lazarus/LCL/GUI units).
- `PascalCase` types and methods, `camelCase` locals, `T`-prefixed types.
- HTTP request/response bodies conform to the `rest/*.schema.json` the console uses.

### SAS
- `.sas` jobs; DATA step and `PROC SQL`. Macro variables `&name`; macro definitions `%macro`.
- Cross-engine reads go through `PROC SQL` explicit pass-through (`CONNECT TO … ; EXECUTE(…)`).
- Fixed-record IO (`INFILE`/`FILE`) matches `contracts/records/sas-report-io.md`.

### ABAP (7.02 subset)
- Stay inside the 7.02 subset; every statement must pass abaplint.
- Upper-case keywords; `snake_case` data objects; classes `lcl_`/`zcl_` per scope.
- The HTTP surface is one ICF handler class implementing `IF_HTTP_EXTENSION~HANDLE_REQUEST`;
  bodies conform to the `rest/gl.*.schema.json` contracts.

## Patterns

- **Contracts are authoritative.** A field's width, type, and JSON↔native mapping come from
  [contracts/data-model.md](contracts/data-model.md). Code conforms to the contract; the contract
  does not chase the code.
- **One altitude per program unit.** A COBOL paragraph, a Fortran subroutine, a Pascal method does
  one thing; extract a named unit rather than commenting a block.
- **No cross-module calls.** A module talks only to its adapter (stdin/stdout records, or HTTP for
  Pascal and ABAP). The gateway orchestrates; modules never reach across the boundary.

## References

- [contracts/README.md](contracts/README.md) — the two marshalling layers and the transfer flow
