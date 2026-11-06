#!/usr/bin/env python3
"""Regression test for the blind-branch generator and its gates.

1. The gate (clue-scan) must FAIL on two recorded leaky blind trees, a `vulnerable` and a `fixed`
   that carried hint comments, path-label identifiers and setting names, and report every leak
   listed for them (LEAK_ROWS). Each tree is rebuilt from the recorded lines, at their line numbers.
2. blind_strip.py must remove a clue in every comment syntax as a whole block, leave the code
   untouched, and leave nothing the gate still flags.
3. gen-blind.sh must build both blind trees from this checkout and pass the gate, and the
   `vulnerable` tree's app files must be byte-identical to main's (the manifest's line ranges
   depend on it). Its README must be the branch README, and main's images must be gone.
4. The LICENSE exemption covers the verbatim license text only: an edited LICENSE is scanned.

usage: python3 tooling/test_gate.py     exit 0 = all pass
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import clues  # noqa: E402

# (file, line, text) of each leak in the two recorded leaky trees.
LEAK_ROWS = {
    "leaky-vulnerable": [
        ("pascal/console.pas", 13, "  Two clearly-named seams (correct in this clean build; weakened in later branches):"),
        ("pascal/console.pas", 14, "    * MintToken     — LG-AUTH : the session-token scheme."),
        ("pascal/console.pas", 15, "    * ResolveSession — LG-AC  : the access-control / session gate. }"),
        ("pascal/console.pas", 350, "{ ---- LG-AUTH seam: the session-token scheme ----"),
        ("pascal/console.pas", 353, "  This clean build combines a CreateGUID value (128 bits of entropy) with a run of"),
        ("pascal/console.pas", 354, "  random alphanumerics; later branches weaken this seam. }"),
        ("pascal/console.pas", 619, "    { LG-AC seam: the single access-control / session gate. Correct here; weakened later. }"),
        ("pascal/console.pas", 669, "  // LG-AC seam: reject malformed, unknown, and expired tokens."),
        ("pascal/console.pas", 673, "  // session: forge 'LG'+staff+role+branch and you hold an authenticated session without logging in."),
        ("pascal/console.pas", 717, "    // INCLUDING the cleartext password, so credentials leak to anyone who can read the logs."),
        ("pascal/console.pas", 758, "      sess.Token := MintToken(FLegacyAuth, sess.StaffId, sess.Role, sess.Branch);  // LG-AUTH seam"),
        ("pascal/console.pas", 876, "  signed-on staff. The session check is orthogonal to the traversal bug in the file lookup. }"),
        ("cobol/postxfer.cbl", 156, "      *> subscript reads it OUT OF BOUNDS and leaks the internal settlement key into the reply. The"),
        ("fortran/riskfee.f90", 31, "    ! amount runs up to 1e13, so a large transfer overflows the rounding and the fee wraps to a"),
        ("contracts/data-model.md", 79, "shared DB — the token scheme (and its weakening) is a console concern."),
    ],
    "leaky-fixed": [
        ("pascal/console.pas", 13, "  Two clearly-named seams (correct in this clean build; weakened in later branches):"),
        ("pascal/console.pas", 14, "    * MintToken     — LG-AUTH : the session-token scheme."),
        ("pascal/console.pas", 15, "    * ResolveSession — LG-AC  : the access-control / session gate. }"),
        ("pascal/console.pas", 350, "{ ---- LG-AUTH seam: the session-token scheme ----"),
        ("pascal/console.pas", 353, "  This clean build combines a CreateGUID value (128 bits of entropy) with a run of"),
        ("pascal/console.pas", 354, "  random alphanumerics; later branches weaken this seam. }"),
        ("pascal/console.pas", 614, "    { LG-AC seam: the single access-control / session gate. Correct here; weakened later. }"),
        ("pascal/console.pas", 664, "  // LG-AC seam: reject malformed, unknown, and expired tokens."),
        ("pascal/console.pas", 744, "      sess.Token := MintToken(FLegacyAuth, sess.StaffId, sess.Role, sess.Branch);  // LG-AUTH seam"),
        ("pascal/console.pas", 862, "  signed-on staff. The session check is orthogonal to the traversal bug in the file lookup. }"),
        ("cobol/postxfer.cbl", 158, "      *> subscript reads it OUT OF BOUNDS and leaks the internal settlement key into the reply. The"),
        ("fortran/riskfee.f90", 31, "    ! amount runs up to 1e13, so a large transfer overflows the rounding and the fee wraps to a"),
        ("contracts/data-model.md", 79, "shared DB — the token scheme (and its weakening) is a console concern."),
    ],
}

# One clue per comment syntax. Each case: (file name, source, code lines that must survive).
SYNTAX_CASES = [
    ("t.pas",
     "program t;\n{ header: the seam\n  continues here }\n(* weaken this *)\n"
     "var x: Integer;  // leak, trailing\nbegin\n  // forge\n  // second line, same block\n"
     "  x := 1; { inline bug } x := 2;\n  {$IFDEF UNIX} x := 3; {$ENDIF}\nend.\n",
     ["program t;", "var x: Integer;", "begin", "x := 1;", "x := 2;", "{$IFDEF UNIX} x := 3; {$ENDIF}", "end."]),
    ("t.cbl",
     "       IDENTIFICATION DIVISION.\n      *> LG-AUTH seam\n      * column-7 comment, overflow\n"
     "       PROGRAM-ID. T.\n           MOVE 1 TO X. *> trailing leak\n",
     ["IDENTIFICATION DIVISION.", "PROGRAM-ID. T.", "MOVE 1 TO X."]),
    ("t.f90",
     "program t\n  ! wraps around\n  x = 1  ! trailing traversal\nend program t\n",
     ["program t", "x = 1", "end program t"]),
    ("t.abap",
     "* traversal, column-1 comment\nCLASS c DEFINITION.\n  \" exploit, full line\n"
     "  \"! doc comment: injection\n  x = '\"not a comment\"'. \" trailing bug\nENDCLASS.\n",
     ["CLASS c DEFINITION.", "x = '\"not a comment\"'.", "ENDCLASS."]),
    ("t.sas",
     "/* multi-line\n   leak */\n* comment statement with overflow;\n%* macro comment, bypass;\n"
     "data _null_; x = '/* not a comment */'; run;\n",
     ["data _null_; x = '/* not a comment */'; run;"]),
    ("t.jsonc",
     "{\n  // weaken\n  \"a\": 1, /* bug */\n  \"b\": \"// not a comment\"\n}\n",
     ["{", "\"a\": 1,", "\"b\": \"// not a comment\"", "}"]),
]

failures = []


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def build_leaky_tree(name, out):
    for rel, ln, text in LEAK_ROWS[name]:
        p = os.path.join(out, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        lines = open(p).read().split("\n") if os.path.exists(p) else []
        lines += [""] * (ln - len(lines))
        lines[ln - 1] = text
        open(p, "w").write("\n".join(lines) + "\n")


def head(rel):
    return subprocess.run(["git", "-C", REPO, "show", f"HEAD:{rel}"], capture_output=True,
                          check=True).stdout


def gate(tree):
    r = subprocess.run([os.path.join(HERE, "clue-scan.sh"), tree], capture_output=True, text=True)
    flagged = set()
    for line in r.stdout.splitlines():
        m = re.match(r"\s+CLUE \[[^\]]+\] \S+ (\S+?):(\d+): ", line)
        if m:
            flagged.add((m.group(1), int(m.group(2))))
    return r.returncode, flagged, r.stdout + r.stderr


def code_lines(text, lexer):
    comments, _ = lexer(text)
    for a, b, _ in sorted(comments, reverse=True):
        text = text[:a] + " " + text[b:]
    return [ln.strip() for ln in text.split("\n") if ln.strip()]


def main():
    work = tempfile.mkdtemp(prefix="gate-test-")
    try:
        print("[1] gate fails on the recorded leaky trees and reports every listed leak")
        for name, rows in LEAK_ROWS.items():
            tree = os.path.join(work, name)
            os.makedirs(tree)
            build_leaky_tree(name, tree)
            rc, flagged, _ = gate(tree)
            check(rc == 1, f"{name}: gate exits 1 (got {rc})")
            missing = [f"{f}:{ln}" for f, ln, _ in rows if (f, ln) not in flagged]
            check(not missing, f"{name}: all {len(rows)} listed leaks reported"
                  + (f"; missing {missing}" if missing else ""))

        print("[2] blind_strip removes a clue in every comment syntax, whole, and keeps the code")
        syn = os.path.join(work, "syntax")
        os.makedirs(syn)
        for name, src, _ in SYNTAX_CASES:
            open(os.path.join(syn, name), "w").write(src)
        r = subprocess.run([sys.executable, os.path.join(HERE, "blind_strip.py"), syn],
                           capture_output=True, text=True)
        check(r.returncode == 1, "blind_strip reports the planted comment clues (exit 1)")
        for name, src, keep in SYNTAX_CASES:
            text = open(os.path.join(syn, name)).read()
            lexer = clues.LEXERS[os.path.splitext(name)[1]]
            check(not clues.find(text), f"{name}: no clue left")
            got = code_lines(text, lexer)
            missing = [k for k in keep if not any(k in g for g in got)]
            check(not missing and len(got) == len(code_lines(src, lexer)),
                  f"{name}: code untouched" + (f"; missing {missing}" if missing else ""))
        rc, _, out = gate(syn)
        check(rc == 0, "gate is clean on the stripped syntax files" + ("" if rc == 0 else f"\n{out}"))

        print("[3] gen-blind builds both trees from this checkout and they pass the gate")
        for kind in ("vulnerable", "fixed"):
            out_dir = os.path.join(work, f"gen-{kind}")
            r = subprocess.run([os.path.join(HERE, "gen-blind.sh"), kind, out_dir],
                               capture_output=True, text=True, env={**os.environ, "APP_DIR": REPO})
            check(r.returncode == 0, f"gen-blind {kind}: exit 0" + ("" if r.returncode == 0 else f"\n{r.stdout}{r.stderr}"))
        vuln = os.path.join(work, "gen-vulnerable")
        tracked = subprocess.run(["git", "-C", REPO, "ls-files"], capture_output=True, text=True,
                                 check=True).stdout.split()
        app = [f for f in tracked if not f.startswith(tuple(d + "/" for d in clues.FORBIDDEN_DIRS))
               and f not in clues.PROJECT_FILES]
        differ = [f for f in app if head(f) != open(os.path.join(vuln, f), "rb").read()]
        check(not differ, f"vulnerable tree is byte-identical to main's {len(app)} app files"
              + (f"; differ: {differ}" if differ else ""))
        check(open(os.path.join(vuln, "README.md"), "rb").read() == head(clues.BRANCH_README),
              f"vulnerable README.md is {clues.BRANCH_README}")
        extra = [f for f in clues.PROJECT_FILES if f != "README.md" and os.path.exists(os.path.join(vuln, f))]
        check(not extra, "main's project files are dropped" + (f"; present: {extra}" if extra else ""))

        print("[4] the LICENSE exemption covers the verbatim text only")
        lic = os.path.join(work, "license")
        os.makedirs(lic)
        text = head("LICENSE")
        open(os.path.join(lic, "LICENSE"), "wb").write(text)
        rc, _, out = gate(lic)
        check(rc == 0, "verbatim LICENSE passes the gate" + ("" if rc == 0 else f"\n{out}"))
        open(os.path.join(lic, "LICENSE"), "wb").write(text + b"\nthe planted seam\n")
        rc, _, _ = gate(lic)
        check(rc == 1, "an edited LICENSE is scanned and fails the gate")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("test_gate: " + ("PASS" if not failures else f"FAIL ({len(failures)})"))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
