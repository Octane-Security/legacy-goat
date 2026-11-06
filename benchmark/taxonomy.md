# Vulnerability taxonomy

The curated CWE-mapped corpus: ~14 classes, one or two strong instances each, placed in the module
where the idiom is native. Present on `main` and `vulnerable` (identical app source; the answer key
is on `main` only); absent on `fixed`. Each instance gets a stable id `LG-<CLASS>-<NNN>` and a `manifest.yaml` entry. Presence is not exploitability: every instance is graded exploitable/unexploitable **per profile** (config/data/state gates), per the exploitability model in [README.md](README.md).

| ID prefix | Class | CWE | Legacy manifestation (module) |
|---|---|---|---|
| LG-SQLI | SQL injection | 89 | dynamic `EXEC SQL` (COBOL, GixSQL); PROC SQL pass-through (SAS); dynamic Open SQL `WHERE` (ABAP) |
| LG-DLII | Hierarchical / DL/I injection | 943 | unsanitized SSA qualification string in DL/I calls (COBOL) |
| LG-VSAM | Indexed-file record enumeration | 639, 566, 20 | attacker-controlled `START KEY IS` / `READ NEXT` positioning → enumeration (keyed traversal, not parser injection) |
| LG-CMDI | OS command injection | 78 | `CALL 'SYSTEM'` (COBOL); `X` / `%SYSEXEC` (SAS); `CALL 'SYSTEM'` / sapxpg (ABAP); `EXECUTE_COMMAND_LINE` (Fortran) |
| LG-PATH | Path / dataset traversal | 22 | dynamic dataset name (COBOL); `OPEN DATASET` (ABAP); `FILENAME` / `INFILE` (SAS); file open (Pascal) |
| LG-MEM | Buffer / memory overflow | 119, 120, 787 | fixed arrays + unchecked reads (Fortran); PIC X reference-mod overrun (COBOL); ShortString / PChar (Pascal) |
| LG-NUM | Integer / decimal overflow & truncation | 190, 197, 681 | COMP-3 packed-decimal truncation (COBOL); integer overflow in money math (Fortran) |
| LG-AUTH | Broken authentication / session | 287, 384 | weak / guessable session token, no expiry (Pascal) |
| LG-AC | Broken access control / IDOR | 639, 862 | authorize on client-supplied account id, no ownership check (Pascal + COBOL) |
| LG-XXE | XXE / unsafe XML | 611 | inbound XML with external entities (ABAP); XML map (SAS) |
| LG-SSRF | Server-side request forgery | 918 | report / fetch action takes a URL or host the backend fetches (ABAP or Pascal) |
| LG-SECR | Insecure crypto / hardcoded secrets | 798, 327 | hardcoded creds / keys (COBOL copybook, SAS macro); weak PIN hashing |
| LG-DESER | Insecure deserialization / unsafe record parse | 502 | reconstructing structures from untrusted serialized input (Pascal / ABAP) |
| LG-BIZ | Financial business-logic flaws | 840, 367 | negative-amount transfer, rounding / salami residue, missing double-entry check, TOCTOU on balance |
| LG-LOG | Log injection / sensitive data in logs (optional) | 117, 532 | unescaped input into logs, secrets logged |

## Sink notes (fidelity-critical)

- **SAS SQLi** lives in PROC SQL explicit pass-through: macro-interpolated `EXECUTE(...)` shipped
  verbatim to the remote engine. The shim must forward pass-through SQL to the real Db2 for the
  injection to be live.
- **ABAP SQLi** needs either the SAP trial or an open-abap transpiler pinned to a version that
  leaves dynamic `WHERE (cond)` unbound; newer transpilers bind literals and neutralize it.
- **LG-VSAM** is keyed positioning / enumeration (IDOR-flavored), not string-parser injection; it
  is labeled that way so scoring is not misleading.
- **LG-DLII** targets the SSA qualification string (`SEGNAME(FIELDNAME op value)`); the injectable
  artifact is the operator/value the caller controls.
