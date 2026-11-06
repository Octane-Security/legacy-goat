#!/usr/bin/env python3
"""Strip benchmark clues from the comments of a blind-branch tree; report what cannot be stripped.

main's app source is written blind: the answer key and every note about it live in benchmark/. On a
correct main this pass finds nothing. It is the backstop. Any comment that carries a clue
(clues.py) is removed together with the rest of its comment block, so no fragment survives. Every
comment syntax in the tree is covered:

  Pascal   // ...   { ... }   (* ... *)          ({$...} compiler directives are code)
  COBOL    *> ...   column-7 '*' or '/' lines
  Fortran  ! ...
  ABAP     " ... (and "! doc comments)   column-1 '*' lines
  SAS      /* ... */   * ... ;   %* ... ;
  JSONC    // ...   /* ... */

Consecutive whole-line comments form one block. A trailing comment is cut back to its code. A
comment left with no words in it (a bare '*>', '{ }') counts as a leftover and is removed too.

Clues outside comments (identifiers, string literals, documents, JSON schema text, XML, file names)
cannot be removed safely. They are reported, and the fix belongs on main.

Removing lines shifts the manifest's line ranges, so gen-blind runs this with --check and fails on
any finding.

usage: blind_strip.py [--check] <tree_dir>
  exit 0 = nothing to strip and nothing unstrippable
  exit 1 = stripped (with --check: would strip) or found unstrippable clues
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clues  # noqa: E402


def line_starts(text):
    starts = [0]
    for i, c in enumerate(text):
        if c == "\n":
            starts.append(i + 1)
    return starts


def line_of(starts, offset):
    return clues._line_index(starts, offset)


def line_end(text, starts, ln):
    return starts[ln + 1] - 1 if ln + 1 < len(starts) else len(text)


def blocks_of(text, comments):
    """Group comment spans into blocks. A block is either a run of whole-line comments on
    consecutive lines, or a single comment that shares a line with code."""
    starts = line_starts(text)
    blocks = []
    for a, b, _ in sorted(comments):
        la = line_of(starts, a)
        lb = line_of(starts, max(a, b - 1))
        prefix = text[starts[la]:a]
        suffix = text[b:line_end(text, starts, lb)]
        whole = prefix.strip() == "" and suffix.strip() == ""
        prev = blocks[-1] if blocks else None
        if whole and prev and prev["whole"] and la == prev["lb"] + 1:
            prev["spans"].append((a, b))
            prev["lb"] = lb
        else:
            blocks.append({"spans": [(a, b)], "whole": whole, "la": la, "lb": lb,
                           "suffix": suffix})
    return blocks, starts


def strip_text(text, lexer):
    """Return (new_text, removed) for one source file."""
    comments, _ = lexer(text)
    blocks, starts = blocks_of(text, comments)
    in_comment = [(a, b) for a, b, _ in comments]
    empties = set(clues.empty_comments(text, comments))
    edits, removed = [], []
    for blk in blocks:
        rules = sorted({r for a, b in blk["spans"] for r, _, _ in clues.find(text[a:b])})
        if not rules and all(a in empties for a, _ in blk["spans"]):
            rules = ["empty-comment"]
        if not rules:
            continue
        a0, b0 = blk["spans"][0][0], blk["spans"][-1][1]
        removed.append((blk["la"] + 1, blk["lb"] + 1, rules, text[a0:b0].split("\n")[0].strip()))
        if blk["whole"]:
            s = starts[blk["la"]]
            e = line_end(text, starts, blk["lb"])
            if e < len(text):
                e += 1  # take the newline with the lines
            elif s > 0:
                s -= 1  # last line of the file: take the preceding newline instead
            edits.append((s, e, ""))
        elif blk["suffix"].strip() == "":
            s = a0
            while s > 0 and text[s - 1] in " \t":
                s -= 1
            edits.append((s, b0, ""))
        else:
            edits.append((a0, b0, " "))
    for s, e, rep in sorted(edits, reverse=True):
        text = text[:s] + rep + text[e:]
    return text, removed


def outside_comments(text, lexer):
    """Clue hits that are not inside a comment: [(rule, line_no, line_text)]."""
    comments, _ = lexer(text) if lexer else ([], [])
    spans = [(a, b) for a, b, _ in comments]
    starts = line_starts(text)
    lines = text.split("\n")
    out, seen = [], set()
    for rule, a, _ in clues.find(text):
        if any(s <= a < e for s, e in spans):
            continue
        ln = line_of(starts, a)
        if (rule, ln) not in seen:
            seen.add((rule, ln))
            out.append((rule, ln + 1, lines[ln]))
    return out


def main(argv):
    args = [a for a in argv[1:] if a != "--check"]
    check = "--check" in argv[1:]
    if len(args) != 1:
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    root = args[0]
    stripped_files, findings = 0, 0
    for d in clues.FORBIDDEN_DIRS:
        if os.path.isdir(os.path.join(root, d)):
            print(f"  keep! {d}/ [forbidden-dir] answer key / generator / CI tree present")
            findings += 1
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(x for x in dns if x != ".git")
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            for rule, _, _ in clues.find(rel):
                print(f"  keep! {rel} [{rule}] filename")
                findings += 1
                break
            if clues.exempt_file(p, rel):
                continue
            text = clues.read_text(p)
            if text is None:
                continue
            lexer = clues.LEXERS.get(os.path.splitext(fn)[1].lower())
            if lexer:
                new, removed = strip_text(text, lexer)
                for la, lb, rules, first in removed:
                    span = f"{la}" if la == lb else f"{la}-{lb}"
                    verb = "would strip" if check else "strip"
                    print(f"  {verb} {rel}:{span} [{','.join(rules)}] {first[:120]}")
                if removed:
                    findings += len(removed)
                    stripped_files += 1
                    if not check:
                        with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                            f.write(new)
                    text = new
            for rule, ln, line in outside_comments(text, lexer):
                print(f"  keep! {rel}:{ln} [{rule}] {line.strip()[:120]}")
                findings += 1
    mode = "check" if check else "strip"
    if findings:
        print(f"blind_strip ({mode}): {findings} finding(s), {stripped_files} file(s) with comment "
              f"clues under {root}; fix the source on main", file=sys.stderr)
        return 1
    print(f"blind_strip ({mode}): nothing to strip under {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
