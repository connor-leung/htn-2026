#!/usr/bin/env python3
"""Lint a Hacker Badge single-file app (manifest header + main.lua).

Usage:
    check_app.py app.lua                 # single-file bundle
    check_app.py manifest.cfg main.lua   # the two IDE files

This is a static lint against the documented sandbox and limits. It does not
compile Lua and cannot predict on-device timing, LVGL allocation, or flash
behaviour. A clean run is not a device test.
"""

import re
import sys

HEADER_OPEN = "--[==[badge-app"
HEADER_CLOSE = "]==]"

REQUIRED_KEYS = {"slug", "name"}
KNOWN_KEYS = {
    "slug", "name", "icon", "api", "heap_kb", "wake_lock",
    "home_button", "confirm_home", "version", "author", "back_button",
}
BOOL_KEYS = {"wake_lock", "home_button", "confirm_home"}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
BUILTIN_SLUGS = {"dice", "reaction", "share", "sync", "settings", "diagnostics",
                 "launcher", "contacts", "lua_countdown"}

MAX_MAIN_BYTES = 64 * 1024

# name -> why it is unavailable
FORBIDDEN = {
    "os": "the os library is absent; use badge.sys.ms()",
    "io": "the io library is absent; use badge.fs",
    "package": "the package library is absent",
    "debug": "the debug library is absent",
    "coroutine": "the coroutine library is absent",
    "pcall": "pcall is removed from the sandbox",
    "xpcall": "xpcall is removed from the sandbox",
    "load": "load is removed; bytecode and dynamic chunks are refused",
    "loadfile": "loadfile is removed from the sandbox",
    "dofile": "dofile is removed from the sandbox",
    "setmetatable": "setmetatable is removed from the sandbox",
}

LIFECYCLE = ("on_enter", "on_tick", "on_button", "on_exit", "on_recv")

BAD_BADGE_CALLS = {
    "badge.led.brightness": "no LED brightness helper exists; scale the RGB channels",
    "badge.led.rainbow": "no LED effect helpers exist; build effects with set/show + on_tick",
    "badge.led.pulse": "no LED effect helpers exist; build effects with set/show + on_tick",
    "badge.sys.sleep": "there is no sleep API; use badge.sys.ms() across ticks",
    "badge.sys.delay": "there is no delay API; use badge.sys.ms() across ticks",
    "badge.audio": "no Lua audio API exists",
    "badge.wifi": "no Lua networking API exists",
    "badge.http": "no Lua networking API exists",
    "badge.net": "no Lua networking API exists",
    "badge.ui.button.set_text": "button:set_text() is unsupported; use a child label",
}

NON_ASCII_OK = set()


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, line, msg):
        self.errors.append((line, msg))

    def warn(self, line, msg):
        self.warnings.append((line, msg))


def split_bundle(text, report):
    """Return (manifest_text, lua_text, lua_line_offset)."""
    lines = text.splitlines()
    # Tolerate a surrounding markdown fence.
    if lines and lines[0].strip().startswith("```"):
        lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]

    if not lines or lines[0].strip() != HEADER_OPEN:
        report.error(1, f"file must start with a line containing exactly {HEADER_OPEN!r}")
        return "", "\n".join(lines), 0

    try:
        close = next(i for i, l in enumerate(lines) if i > 0 and l.strip() == HEADER_CLOSE)
    except StopIteration:
        report.error(1, f"manifest header is never closed with {HEADER_CLOSE!r} on its own line")
        return "", "", 0

    manifest = "\n".join(lines[1:close])
    lua = "\n".join(lines[close + 1:])
    return manifest, lua, close + 1


def check_manifest(manifest, report, base_line=1):
    seen = {}
    for i, raw in enumerate(manifest.splitlines(), start=base_line + 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            report.error(i, f"manifest line is not key=value: {line!r}")
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key in seen:
            report.error(i, f"duplicate manifest key {key!r}")
        seen[key] = value
        if key not in KNOWN_KEYS:
            report.error(i, f"unknown manifest key {key!r}")
        if "#" in value:
            report.warn(i, "inline comments are not supported in manifest values")
        if key in BOOL_KEYS and value not in ("0", "1"):
            report.error(i, f"{key} must be 0 or 1, got {value!r}")

    for key in sorted(REQUIRED_KEYS - set(seen)):
        report.error(base_line, f"missing required manifest key {key!r}")

    slug = seen.get("slug")
    if slug is not None:
        if not SLUG_RE.match(slug):
            report.error(base_line, f"slug {slug!r} must match [a-z0-9][a-z0-9_-]{{0,31}}")
        if slug in BUILTIN_SLUGS:
            report.error(base_line, f"slug {slug!r} collides with a built-in app")

    name = seen.get("name")
    if name is not None and not 1 <= len(name.encode()) <= 48:
        report.error(base_line, "name must be 1-48 bytes")

    icon = seen.get("icon")
    if icon is not None:
        if not 1 <= len(icon.encode()) <= 12:
            report.error(base_line, "icon must be 1-12 bytes")
        if not icon.isascii():
            report.error(base_line, "icon must be ASCII; the text icon is not an emoji renderer")

    api = seen.get("api", "1")
    if api not in ("1", "2"):
        report.error(base_line, f"api must be 1 or 2, got {api!r}")
    elif api != "2":
        report.warn(base_line, "new apps should set api=2")

    heap = seen.get("heap_kb")
    if heap is not None and heap not in ("48", "96"):
        report.error(base_line, f"heap_kb must be 48 or 96, got {heap!r}")

    if seen.get("home_button") == "1" and seen.get("confirm_home") == "1":
        report.error(base_line, "home_button=1 cannot be combined with confirm_home=1")

    return seen


def strip_lua_noise(lua):
    """Blank out comments and string bodies so scans do not fire inside them.

    Keeps line structure intact.
    """
    out = []
    i, n = 0, len(lua)
    while i < n:
        ch = lua[i]
        if ch == "-" and lua.startswith("--", i):
            m = re.match(r"--\[(=*)\[", lua[i:])
            if m:
                close = "]" + m.group(1) + "]"
                end = lua.find(close, i)
                end = n if end == -1 else end + len(close)
                out.append(re.sub(r"[^\n]", " ", lua[i:end]))
                i = end
                continue
            end = lua.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue
        if ch in "\"'":
            j = i + 1
            while j < n and lua[j] != ch:
                j += 2 if lua[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(re.sub(r"[^\n]", " ", lua[i:j]))
            i = j
            continue
        m = re.match(r"\[(=*)\[", lua[i:])
        if m:
            close = "]" + m.group(1) + "]"
            end = lua.find(close, i)
            end = n if end == -1 else end + len(close)
            out.append(re.sub(r"[^\n]", " ", lua[i:end]))
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_lua(lua, report, offset, manifest):
    size = len(lua.encode())
    if size > MAX_MAIN_BYTES:
        report.error(offset, f"main.lua is {size} bytes, over the {MAX_MAIN_BYTES} byte cap")
    elif size > MAX_MAIN_BYTES * 0.75:
        report.warn(offset, f"main.lua is {size} bytes; compilation memory, not the "
                            "upload cap, is usually the real ceiling")

    code = strip_lua_noise(lua)
    code_lines = code.splitlines()
    raw_lines = lua.splitlines()

    for idx, line in enumerate(code_lines):
        ln = offset + idx + 1

        for name, why in FORBIDDEN.items():
            if re.search(rf"(?<![\w.]){re.escape(name)}\s*[.(]", line):
                report.error(ln, f"{name} is unavailable: {why}")

        for call, why in BAD_BADGE_CALLS.items():
            if call in line:
                report.error(ln, f"{call} does not exist: {why}")

        if manifest.get("api", "1") == "2":
            m = re.search(r"badge\.(label|box)\s*\(", line)
            if m:
                report.error(ln, f"badge.{m.group(1)}() is api=1 only; use badge.ui.{m.group(1)}()")

        if re.search(r"\brequire\s*\(", line):
            report.warn(ln, "require() needs the module shipped alongside the app; "
                            "prefer a self-contained main.lua")

        for cb in LIFECYCLE:
            if re.search(rf"\blocal\s+function\s+{cb}\b", line) or \
               re.search(rf"\blocal\s+{cb}\s*=\s*function\b", line):
                report.error(ln, f"{cb} must be a global function, not a local")

        if re.search(r"\bwhile\s+true\s+do\b", line):
            report.warn(ln, "unbounded loop: there is no sleep and callbacks have deadlines")

        if re.search(r"badge\.(input\.BUTTON|input\.KIND)\s*\[\s*[\"']", line):
            report.warn(ln, "use the named constants, e.g. badge.input.BUTTON.A")

        if re.search(r"badge\.(store|fs)\.(set|set_int|set_str|write|append)\s*\(", line):
            report.warn(ln, "flash write: make sure this is not on a per-tick path")

    for idx, line in enumerate(raw_lines):
        ln = offset + idx + 1
        # String bodies are blanked in `code`, so scan the raw line for these.
        if re.search(r"\b(button|btn|b|key|press)\s*==\s*"
                     r"[\"'](A|B|HOME|UP|DOWN|LEFT|RIGHT|START|AUX1)[\"']", line):
            report.error(ln, "buttons are integers; compare against badge.input.BUTTON.*")
        if re.search(r"KIND\s*==\s*[\"'](PRESSED|RELEASED)[\"']", line):
            report.error(ln, "button kinds are integers; use badge.input.KIND.PRESSED")
        if not line.isascii():
            bad = sorted({c for c in line if not c.isascii()})
            report.warn(ln, "non-ASCII character(s) " + " ".join(repr(c) for c in bad) +
                            "; bundled fonts render these as boxes")

    if "function on_enter" not in code:
        report.error(offset, "no global on_enter(root) defined")

    led_writes = len(re.findall(r"badge\.led\.(set|set_all|clear)\s*\(", code))
    led_shows = len(re.findall(r"badge\.led\.show\s*\(", code))
    if led_writes and not led_shows:
        report.error(offset, "badge.led writes without any badge.led.show(); nothing will light up")
    if led_writes and led_shows and "function on_exit" not in code:
        report.warn(offset, "LEDs are used but there is no on_exit to clear them")

    if re.search(r"badge\.(nfc|radio)\.enable\s*\(", code) and \
       not re.search(r"(if|local|not|=)\s*[^\n]*badge\.(nfc|radio)\.enable", code):
        report.warn(offset, "check the result of nfc/radio enable() and handle failure")

    widgets = len(re.findall(r"badge\.ui\.\w+\s*[({]", code))
    if widgets > 120:
        report.warn(offset, f"{widgets} widget factory calls in source; the live cap is 512 "
                            "and large UIs should be built a few per tick")


def main(argv):
    if len(argv) == 2:
        path = argv[1]
        with open(path, encoding="utf-8") as f:
            text = f.read()
        report = Report()
        manifest_text, lua, offset = split_bundle(text, report)
        manifest = check_manifest(manifest_text, report)
        check_lua(lua, report, offset, manifest)
        label = path
    elif len(argv) == 3:
        with open(argv[1], encoding="utf-8") as f:
            manifest_text = f.read()
        with open(argv[2], encoding="utf-8") as f:
            lua = f.read()
        report = Report()
        manifest = check_manifest(manifest_text, report, base_line=0)
        check_lua(lua, report, 0, manifest)
        label = f"{argv[1]} + {argv[2]}"
    else:
        print(__doc__)
        return 2

    for line, msg in sorted(report.errors):
        print(f"{label}:{line}: error: {msg}")
    for line, msg in sorted(report.warnings):
        print(f"{label}:{line}: warning: {msg}")

    print(f"\n{len(report.errors)} error(s), {len(report.warnings)} warning(s).")
    if not report.errors:
        print("Static checks passed. This is not a compile and not a device test: "
              "open the app on the badge to verify timing, memory, and behaviour.")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
