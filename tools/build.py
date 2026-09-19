#!/usr/bin/env python3
"""Build goose_duel.lua (the file you Import) from manifest.cfg + main.lua.

Comments, blank lines and indentation are stripped from the shipped copy. The badge
compiles the whole file before on_enter runs, and that compile is what hits
the Lua memory ceiling, so every byte of source the badge never needs is
worth removing. main.lua itself stays commented and readable.

Strings are respected: a "--" inside a string literal is not a comment.

    python3 tools/build.py            # writes goose_duel.lua
    python3 tools/build.py --check    # report sizes only
"""

import re
import sys

MAIN = "main.lua"
MANIFEST = "manifest.cfg"
OUT = "goose_duel.lua"


def strip_line(line):
    """Return `line` with any real comment removed (None if nothing is left)."""
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if ch in "\"'":                       # skip a string literal
            q = ch
            i += 1
            while i < n and line[i] != q:
                i += 2 if line[i] == "\\" else 1
            i += 1
            continue
        if line.startswith("--", i):
            # a long comment --[[ ... ]] would need multi-line handling; this
            # app has none, so refuse rather than silently corrupt the file
            if re.match(r"--\[=*\[", line[i:]):
                raise SystemExit("build.py: long comments are not supported")
            line = line[:i]
            break
        i += 1
    out = line.rstrip()
    return out if out.strip() else None


def main():
    with open(MAIN, encoding="utf-8") as f:
        src = f.read()
    with open(MANIFEST, encoding="utf-8") as f:
        manifest = f.read().rstrip("\n")

    # A long-bracket string would make indentation significant; this app has
    # none, and silently reflowing one would corrupt it.
    if re.search(r"(?<!-)\[=*\[", src):
        raise SystemExit("build.py: long-bracket strings are not supported")

    kept = []
    for line in src.splitlines():
        s = strip_line(line)
        if s is not None:
            # Lua ignores leading whitespace, and it is ~10% of the source the
            # badge has to lex before on_enter runs.
            kept.append(s.lstrip())
    body = "\n".join(kept) + "\n"

    bundle = "--[==[badge-app\n" + manifest + "\n]==]\n\n" + body

    if "--check" not in sys.argv:
        with open(OUT, "w", encoding="utf-8") as f:
            f.write(bundle)

    print(f"{MAIN}: {len(src.encode()):,} B  ->  shipped body {len(body.encode()):,} B "
          f"({100 - 100 * len(body.encode()) // len(src.encode())}% smaller)")
    print(f"{OUT}: {len(bundle.encode()):,} B")


if __name__ == "__main__":
    main()
