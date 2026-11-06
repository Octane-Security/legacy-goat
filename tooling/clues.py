#!/usr/bin/env python3
"""Benchmark clues: the vocabulary, the comment lexers and the blind-tree scan.

Shared by the clue-scan gate (clue-scan.sh runs `clues.py <tree>`) and blind_strip.py, so the two
never disagree on what a clue is.

A clue is any text that would tell a scanner where a planted weakness is, what it does, or that the
tree is a benchmark at all:
  - marker ids, numbered or not (LG-AUTH, LG-SQLI-001), CWE / CVE / OWASP references;
  - weakness vocabulary (leak, forge, traversal, overflow, unsafe, bypass, ...);
  - path labels (safe/unsafe/vuln/legacy) in comments AND identifiers, strings and setting names;
  - benchmark vocabulary (seam, clean build, later branch, gate, profile, ground truth, ...);
  - the "goat" naming convention of deliberately vulnerable training apps.

The gate scans ALL text: code identifiers, string literals, comments, documents, JSON schema text,
XML and file names. The per-language lexers below only label the channel (comment / string / code)
and tell blind_strip.py which comment blocks it may remove.

Config settings are app configuration, so their presence is never a clue, but their names are held to
the same vocabulary as any other identifier.

usage: clues.py <tree_dir>     exit 0 = clean, 1 = clues found, 2 = bad usage
"""
import hashlib
import os
import re
import sys

# (rule, regex). Case-insensitive unless the pattern sets (?-i) itself.
PATTERNS = [
    ("marker-id", r"(?-i:\bLG-[A-Z]{2,}(?:-[0-9]+)?\b)"),
    ("cwe-cve", r"\bCWE[- ]?[0-9]+|\bCVE-[0-9]{4}|\bOWASP\b"),
    ("weakness-acronym", r"(?-i:\b(?:XSS|XXE|SSRF|CSRF|SQLi|SQLI|IDOR|RCE|LFI|RFI)\b)"),
    ("path-label", r"safe|vuln|legacy|insecure|\bweak|\bharden"),
    ("weakness-word",
     r"exploit|inject|payload|attack|malicious|backdoor|saniti[sz]|\bevil\b|bypass|tamper|spoof"
     r"|\bleak|\bforg(?:e|es|ed|ery|eries|ing|eable|eability)\b|clear-?text|travers"
     r"|out[- ]of[- ]bounds?|overflow|\bwrap|\bbugs?\b|privilege escalation"
     r"|unescaped|unsaniti[sz]ed|unvalidated|unchecked|untrusted|arbitrary|in the clear|\breflected\b"
     r"|mitigat|allow-?list|white-?list|deny-?list|black-?list|raw path"
     r"|(?:caller|user|client|attacker)[- ](?:controlled|supplied)"),
    ("attack-sample", r"<!ENTITY|<script|file:///|'\s*OR\s*'1'\s*=\s*'1|UNION\s+SELECT|/etc/passwd"
     r"|169\.254\.169\.254"),
    ("benchmark-word",
     r"\bseams?\b|clean build|later branch|weaken|hard[- ]negative|benchmark|ground[- ]truth"
     r"|answer[- ]key|\bgat(?:e|es|ed|ing)\b|\bprofiles?\b|APP_PROFILE|\bpermissive\b"
     r"|\bknobs?\b|\btriggers?\b|\brecipes?\b|the fix\b|goat"),
    ("todo-marker", r"(?-i:\b(?:TODO|FIXME|HACK|XXX)\b)"),
]
COMPILED = [(rule, re.compile(rx, re.IGNORECASE)) for rule, rx in PATTERNS]

# Tokens kept on purpose, masked before matching. Each needs a reason as its value.
EXEMPT_TOKENS: dict = {}

# Files whose text is not scanned when it is exactly this content: (sha256, reason). Any edit puts the
# file back under the scan.
EXEMPT_FILES = {
    "LICENSE": ("3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986",
                "the GNU GPL v3 text, verbatim"),
}

# Trees a blind branch must never carry.
FORBIDDEN_DIRS = ("benchmark", "tooling", ".github")

# main's project front page and its images. A blind branch carries tooling/branch-README.md as its
# README and neither image.
PROJECT_FILES = ("README.md", "legacy-goat-sm.png", "legacy-goat-console.png")
BRANCH_README = "tooling/branch-README.md"

# ---------------------------------------------------------------------------------------------
# Lexers. Each returns (comments, strings): lists of (start, end) character offsets.
# A comment span may carry kind "line" (to end of line) or "block"/"stmt" (delimited).


def _scan_quoted(text, i, quote, doubling=True, backslash=False):
    """Return the offset just past the string literal that opens at text[i] == quote."""
    j = i + 1
    n = len(text)
    while j < n:
        c = text[j]
        if backslash and c == "\\":
            j += 2
            continue
        if c == quote:
            if doubling and j + 1 < n and text[j + 1] == quote:
                j += 2
                continue
            return j + 1
        if c == "\n" and not backslash:
            return j  # unterminated on this line; stop at EOL
        j += 1
    return n


def _eol(text, i):
    j = text.find("\n", i)
    return len(text) if j < 0 else j


def lex_pascal(text):
    comments, strings = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = _scan_quoted(text, i, "'")
            strings.append((i, j))
            i = j
        elif text.startswith("//", i):
            j = _eol(text, i)
            comments.append((i, j, "line"))
            i = j
        elif c == "{":
            j = text.find("}", i)
            j = n if j < 0 else j + 1
            if not text.startswith("{$", i):  # {$...} is a compiler directive, not a comment
                comments.append((i, j, "block"))
            i = j
        elif text.startswith("(*", i):
            j = text.find("*)", i + 2)
            j = n if j < 0 else j + 2
            comments.append((i, j, "block"))
            i = j
        else:
            i += 1
    return comments, strings


def _lex_lines(text, per_line):
    """Run a per-line lexer; per_line(line) -> (comments, strings) with line-relative offsets."""
    comments, strings = [], []
    off = 0
    for line in text.split("\n"):
        cs, ss = per_line(line)
        comments += [(off + a, off + b, k) for a, b, k in cs]
        strings += [(off + a, off + b) for a, b in ss]
        off += len(line) + 1
    return comments, strings


def _line_comment(line, starts, quotes, full_line=None):
    """Find string literals and the first to-EOL comment opener outside them."""
    if full_line and full_line(line):
        return [(0, len(line), "line")], []
    strings = []
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c in quotes:
            j = _scan_quoted(line, i, c)
            strings.append((i, j))
            i = j
            continue
        for s in starts:
            if line.startswith(s, i):
                return [(i, n, "line")], strings
        i += 1
    return [], strings


def lex_cobol(text):
    # Fixed format: '*' or '/' in column 7 makes the whole line a comment; '*>' opens a floating
    # comment anywhere outside a literal.
    def full(line):
        return len(line) > 6 and line[6] in "*/"
    return _lex_lines(text, lambda ln: _line_comment(ln, ("*>",), "\"'", full))


def lex_fortran(text):
    return _lex_lines(text, lambda ln: _line_comment(ln, ("!",), "\"'"))


def lex_abap(text):
    def full(line):
        return line.startswith("*")
    return _lex_lines(text, lambda ln: _line_comment(ln, ('"',), "'`|", full))


def lex_sas(text):
    # /* ... */ anywhere; '* ... ;' and '%* ... ;' comment statements at a statement start.
    comments, strings = [], []
    i, n = 0, len(text)
    stmt_start = True
    while i < n:
        c = text[i]
        if c in "'\"":
            j = _scan_quoted(text, i, c)
            strings.append((i, j))
            i = j
            stmt_start = False
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            comments.append((i, j, "block"))
            i = j
        elif stmt_start and (c == "*" or text.startswith("%*", i)):
            j = text.find(";", i)
            j = n if j < 0 else j + 1
            comments.append((i, j, "stmt"))
            i = j
        else:
            if c == ";":
                stmt_start = True
            elif not c.isspace():
                stmt_start = False
            i += 1
    return comments, strings


def lex_jsonc(text):
    comments, strings = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = _scan_quoted(text, i, '"', doubling=False, backslash=True)
            strings.append((i, j))
            i = j
        elif text.startswith("//", i):
            j = _eol(text, i)
            comments.append((i, j, "line"))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            comments.append((i, j, "block"))
            i = j
        else:
            i += 1
    return comments, strings


LEXERS = {
    ".pas": lex_pascal, ".pp": lex_pascal, ".dpr": lex_pascal, ".inc": lex_pascal,
    ".cbl": lex_cobol, ".cob": lex_cobol, ".cpy": lex_cobol,
    ".f90": lex_fortran, ".f95": lex_fortran, ".f": lex_fortran, ".for": lex_fortran,
    ".abap": lex_abap,
    ".sas": lex_sas,
    ".jsonc": lex_jsonc,
}
DOC_CHANNEL = {".md": "doc", ".json": "schema", ".xml": "xml"}

# ---------------------------------------------------------------------------------------------


def mask(text):
    for tok in EXEMPT_TOKENS:
        text = text.replace(tok, " " * len(tok))
    return text


def find(text):
    """[(rule, start, end)] for every clue in text (exempt tokens masked)."""
    masked = mask(text)
    hits = []
    for rule, rx in COMPILED:
        for m in rx.finditer(masked):
            hits.append((rule, m.start(), m.end()))
    return hits


def is_clue(text):
    return bool(find(text))


def read_text(path):
    with open(path, "rb") as f:
        raw = f.read()
    if b"\0" in raw:
        return None
    return raw.decode("utf-8", errors="surrogateescape")


def channel_of(offset, comments, strings, default):
    for a, b, *_ in comments:
        if a <= offset < b:
            return "comment"
    for a, b in strings:
        if a <= offset < b:
            return "string"
    return default


# A comment with no words left in it, e.g. a bare '*>' or '{ }': what a careless strip leaves behind.
EMPTY_COMMENT = re.compile(r"^[\s{}()*/!\"'%;>-]*$")


def empty_comments(text, comments):
    """Offsets of comments that carry no text at all."""
    return [a for a, b, _ in comments if EMPTY_COMMENT.match(text[a:b])]


def exempt_file(path, rel):
    entry = EXEMPT_FILES.get(rel)
    if entry is None:
        return False
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest() == entry[0]


def scan_file(path, rel):
    """[(rule, channel, line_no, line_text)] for one file."""
    if exempt_file(path, rel):
        return []
    text = read_text(path)
    if text is None:
        return []
    ext = os.path.splitext(path)[1].lower()
    lexer = LEXERS.get(ext)
    comments, strings = lexer(text) if lexer else ([], [])
    default = "code" if lexer else DOC_CHANNEL.get(ext, "text")
    starts = [0]
    for i, c in enumerate(text):
        if c == "\n":
            starts.append(i + 1)
    lines = text.split("\n")
    out, seen = [], set()
    hits = find(text) + [("empty-comment", a, a) for a in empty_comments(text, comments)]
    for rule, a, _ in hits:
        ln = _line_index(starts, a)
        key = (rule, ln)
        if key in seen:
            continue
        seen.add(key)
        out.append((rule, channel_of(a, comments, strings, default), ln + 1, lines[ln]))
    return out


def _line_index(starts, offset):
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= offset:
            lo = mid
        else:
            hi = mid - 1
    return lo


def scan_tree(root):
    """All clues under root: [(rule, channel, rel_path, line_no, text)]."""
    found = []
    for d in FORBIDDEN_DIRS:
        if os.path.isdir(os.path.join(root, d)):
            found.append(("forbidden-dir", "tree", d + "/", 0, "answer key / generator / CI tree present"))
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(x for x in dns if x != ".git")
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            for rule, _, _ in find(rel):
                found.append((rule, "filename", rel, 0, rel))
                break
            for rule, ch, ln, txt in scan_file(p, rel):
                found.append((rule, ch, rel, ln, txt))
    return found


def main(argv):
    if len(argv) != 2:
        print("usage: clues.py <tree_dir>", file=sys.stderr)
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        print(f"clue-scan: no such dir: {root}", file=sys.stderr)
        return 2
    found = scan_tree(root)
    for rule, ch, rel, ln, txt in found:
        loc = f"{rel}:{ln}" if ln else rel
        print(f"  CLUE [{rule}] {ch} {loc}: {txt.strip()[:160]}")
    if found:
        files = len({f[2] for f in found})
        print(f"clue-scan: FAIL ({len(found)} clue(s) in {files} file(s) under {root})", file=sys.stderr)
        return 1
    print(f"clue-scan: clean ({root} has no benchmark clues)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
