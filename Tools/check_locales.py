#!/usr/bin/env python3
"""Locale consistency checker for VeevHUD (AceLocale-3.0).

Why this exists: VeevHUD keys every string by its English text (L["English"]).
That's readable and contributor-friendly, but it means editing an English string
in code/enUS leaves the OLD text as a now-orphaned key in every translation file
(which then silently falls back to English). This script makes that -- and any
placeholder/color-code damage -- loud instead of silent.

Checks (HARD = exit 1, blocks CI; WARN = reported, non-blocking):
  HARD  every L["..."] used in code is defined in enUS.lua   (else AceLocale errors)
  HARD  every locale line is a valid L["k"] = true|"v" assignment (structural)
  HARD  no duplicate keys within a single locale file (an earlier one silently loses)
  HARD  no "stale" keys: a translation key not present in enUS
        (the signal that English changed and that translation needs updating)
  HARD  %s / %d format-specifier multiset matches between key and value
        (a missing/extra %s in a :format() string is a runtime error)
  HARD  |cff..|r, |T..|t and |H..|h escape counts match between key and value
  HARD  no dynamic L[...] indexing -- AceLocale is strict here (enUS declares no
        `silent` flag), so L[someVar] raises for any key it does not know.
        Annotate a guarded lookup with a trailing "-- locale-ok" comment.
  HARD  each Locales/<x>.lua declares NewLocale("VeevHUD", "<x>") matching its own
        filename, only enUS passes isDefault=true, and every file is listed in the
        TOC with enUS first
  HARD  translation coverage at or above the floor (default 100%; override with
        VEEVHUD_LOCALE_COVERAGE_FLOOR). Untranslated keys fall back to English
        silently, so without a floor translations drift behind unnoticed -- which
        is exactly how all 10 locales quietly fell to 97%.
  WARN  hardcoded English that looks user-facing but is not wrapped in L[]
        (AceConfig name=/desc=/usage= and :SetText/:AddLine prose). Heuristic, so
        it only warns -- annotate a deliberate exception with "-- locale-ok".
  WARN  enUS keys not referenced anywhere in code (dead entries)

Run locally:  python3 Tools/check_locales.py
Runs in CI on every push/PR (see .github/workflows/release.yml).
"""
import os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCALES = ROOT / "Locales"
TOC = ROOT / "VeevHUD.toc"

COVERAGE_FLOOR = float(os.environ.get("VEEVHUD_LOCALE_COVERAGE_FLOOR", "100"))

STR = r'(?:\\.|[^"\\])*'                      # Lua double-quoted body (escape-aware)
KEY_USE_RE = re.compile(r'\bL\["(' + STR + r')"\]')
ENUS_RE = re.compile(r'^L\["(' + STR + r')"\]\s*=\s*true\s*$')
TR_RE   = re.compile(r'^L\["(' + STR + r')"\]\s*=\s*"(' + STR + r')"\s*$')
FMT_RE  = re.compile(r'%\d*\.?\d*[sdfgxXq%]')  # real format specifiers (not literal "100%")
NEWLOCALE_RE = re.compile(r'NewLocale\(\s*"VeevHUD"\s*,\s*"([^"]+)"\s*(?:,\s*(true|false))?')

# A dynamic index is any L[ not immediately followed by a double quote.
DYNAMIC_L_RE = re.compile(r'\bL\[\s*(?!")')
OPT_OUT = "locale-ok"

# WoW UI escape sequences that must survive translation intact.
ESCAPES = {
    "|cff": (re.compile(r'\|c[fF][fF][0-9a-fA-F]{6}'), re.compile(r'\|r')),
    "|T":   (re.compile(r'\|T[^|]*\|t'), None),
    "|H":   (re.compile(r'\|H[^|]*\|h'), None),
}

# Directories that are not VeevHUD runtime Lua. Generated packages contain
# embedded AceLocale consumers, and source tooling can contain Lua snippets;
# treating either as VeevHUD code creates false failures.
SKIP_PARTS = {
    ".agents", ".claude", ".git", ".github", ".release",
    "Libs", "Locales", "Tools",
}

hard, warn = [], []


def addon_lua_files():
    for p in sorted(ROOT.rglob("*.lua")):
        if set(p.relative_to(ROOT).parts) & SKIP_PARTS:
            continue
        yield p


def parse_locale(path, is_default):
    """Parse a Locales/*.lua into {key: value}; collect structural errors."""
    kv, errs, dupes, in_block = {}, [], [], False
    for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        s = raw.strip()
        if in_block:
            if "]]" in s: in_block = False
            continue
        if s.startswith("--[["):
            if "]]" not in s: in_block = True
            continue
        if not s or s.startswith("--") or s.startswith("local L") or s.startswith("if not L"):
            continue
        m = (ENUS_RE if is_default else TR_RE).match(s)
        if not m:
            errs.append((n, raw[:80])); continue
        key = m.group(1)
        if key in kv:
            dupes.append((n, key))
        kv[key] = True if is_default else m.group(2)
    return kv, errs, dupes


def strip_lua_comment(line):
    """Drop a trailing -- comment, ignoring -- that appears inside a string."""
    in_str, quote, i = False, "", 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2; continue
            if ch == quote:
                in_str = False
        elif ch in "\"'":
            in_str, quote = True, ch
        elif ch == "-" and line[i + 1:i + 2] == "-":
            return line[:i]
        i += 1
    return line


def escape_counts(text):
    counts = {}
    for label, (open_re, close_re) in ESCAPES.items():
        counts[label] = len(open_re.findall(text))
        if close_re is not None:
            counts[label + "-close"] = len(close_re.findall(text))
    return counts


ANY_LITERAL_RE = re.compile(r'"(' + STR + r')"')


def scan_code_keys():
    """Collect every L["literal"] used in runtime Lua, and flag dynamic lookups.

    Also collects every bare double-quoted literal, so that keys reached only
    through a guarded dynamic lookup (Utils:LocalizeUIName over the English
    names in Constants.lua) are not misreported as dead entries.
    """
    keys, literals = set(), set()
    for p in addon_lua_files():
        rel = p.relative_to(ROOT)
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            for m in KEY_USE_RE.finditer(line):
                keys.add(m.group(1))
            for m in ANY_LITERAL_RE.finditer(line):
                literals.add(m.group(1))
            if DYNAMIC_L_RE.search(line) and OPT_OUT not in line:
                hard.append(
                    "%s:%d dynamic L[...] lookup -- AceLocale is strict and errors on an "
                    "unknown key. Use a literal, or add a trailing '-- %s' comment if the "
                    "lookup is guarded: %s" % (rel, n, OPT_OUT, line.strip()[:70])
                )
    return keys, literals


# Heuristic hardcoded-English detection ---------------------------------------
# Deliberately narrow: prose only, and only in the string-rendering call shapes
# VeevHUD actually uses. Warns rather than hard-fails because it cannot know
# whether a given literal is display text or an internal token.
OPTION_FIELD_RE = re.compile(r'\b(?:name|desc|usage|confirmText)\s*=\s*"(' + STR + r')"')
SETTEXT_RE = re.compile(r':(?:SetText|AddLine|AddDoubleLine)\(\s*"(' + STR + r')"')
PROSE_RE = re.compile(r'[A-Za-z]{2,}\s+[A-Za-z]')   # at least two words


def looks_like_prose(text):
    if not text or len(text) < 4:
        return False
    stripped = re.sub(r'\|c[fF][fF][0-9a-fA-F]{6}|\|r|\|T[^|]*\|t', '', text)
    if not stripped.strip():
        return False
    if stripped.startswith(("Interface\\", "Fonts\\", "Sound\\", "/")):
        return False
    return bool(PROSE_RE.search(stripped))


def scan_hardcoded_english():
    hits = []
    for p in addon_lua_files():
        rel = p.relative_to(ROOT)
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if OPT_OUT in line:
                continue
            code = strip_lua_comment(line)
            for rx in (OPTION_FIELD_RE, SETTEXT_RE):
                for m in rx.finditer(code):
                    if looks_like_prose(m.group(1)):
                        hits.append("%s:%d %s" % (rel, n, m.group(1)[:60]))
    return hits


# --- enUS (source of truth) ---
enus_path = LOCALES / "enUS.lua"
if not enus_path.exists():
    print("FATAL: Locales/enUS.lua not found"); sys.exit(2)
enus, enus_errs, enus_dupes = parse_locale(enus_path, True)
enus_set = set(enus)
for n, line in enus_errs:
    hard.append("enUS.lua:%d unparseable line: %s" % (n, line))
for n, key in enus_dupes:
    hard.append("enUS.lua:%d duplicate key (the earlier definition is silently overwritten): %r" % (n, key))

# --- code vs enUS ---
code_keys, code_literals = scan_code_keys()
missing = code_keys - enus_set
if missing:
    for k in sorted(missing)[:10]:
        hard.append("code uses L[%r] but enUS.lua does not define it (AceLocale will error)" % k)
unused = enus_set - code_keys - code_literals
if unused:
    warn.append("%d enUS keys defined but never used in code, e.g. %r" % (len(unused), sorted(unused)[:3]))

# --- TOC wiring ---
toc_order, toc_text = [], ""
if TOC.exists():
    toc_text = TOC.read_text(encoding="utf-8")
    for line in toc_text.splitlines():
        s = line.strip()
        if s.lower().startswith("locales\\") and s.lower().endswith(".lua"):
            toc_order.append(Path(s.replace("\\", "/")).stem)
    if toc_order and toc_order[0] != "enUS":
        hard.append("VeevHUD.toc lists %r before enUS.lua; the default locale must load first" % toc_order[0])
else:
    hard.append("VeevHUD.toc not found -- cannot verify locale load order")

# --- structural wiring of every locale file ---
locale_files = sorted(p for p in LOCALES.glob("*.lua") if p.stem != "enUS")
print("enUS source keys: %d | translations: %d | coverage floor: %g%%\n"
      % (len(enus_set), len(locale_files), COVERAGE_FLOOR))

for path in [enus_path] + locale_files:
    loc = path.stem
    if toc_text and loc not in toc_order:
        hard.append("%s: present in Locales/ but not listed in VeevHUD.toc (it would never load)" % loc)
    m = NEWLOCALE_RE.search(path.read_text(encoding="utf-8"))
    if not m:
        hard.append('%s: no NewLocale("VeevHUD", ...) call found' % loc)
    else:
        if m.group(1) != loc:
            hard.append("%s: declares NewLocale(..., %r) but the filename says %r "
                        "(the declared code wins, so this file would never apply)" % (loc, m.group(1), loc))
        if loc == "enUS" and m.group(2) != "true":
            hard.append("enUS: NewLocale must pass isDefault=true so missing keys fall back to English")
        elif loc != "enUS" and m.group(2) == "true":
            hard.append("%s: NewLocale must not pass isDefault=true (only enUS is the default)" % loc)

# --- each translation ---
for path in locale_files:
    loc = path.stem
    kv, errs, dupes = parse_locale(path, False)
    for n, line in errs:
        hard.append("%s:%d unparseable line: %s" % (path.name, n, line))
    for n, key in dupes:
        hard.append("%s:%d duplicate key (the earlier translation is silently overwritten): %r" % (path.name, n, key))
    stale = sorted(set(kv) - enus_set)
    for k in stale[:10]:
        hard.append("%s: stale key not in enUS (English changed? remove or re-key): %r" % (loc, k))
    for k, v in kv.items():
        if k not in enus_set:
            continue
        if sorted(FMT_RE.findall(k)) != sorted(FMT_RE.findall(v)):
            hard.append("%s: format specifiers differ for %r -> %r" % (loc, k[:40], v[:50]))
        if escape_counts(k) != escape_counts(v):
            hard.append("%s: UI escape counts differ (|cff/|r, |T..|t, |H..|h) for %r" % (loc, k[:40]))
    covered = len(set(kv) & enus_set)
    pct = 100.0 * covered / max(1, len(enus_set))
    below = pct + 1e-9 < COVERAGE_FLOOR
    if below:
        gap = sorted(enus_set - set(kv))
        hard.append("%s: coverage %.1f%% is below the %g%% floor -- %d key(s) untranslated, e.g. %r"
                    % (loc, pct, COVERAGE_FLOOR, len(gap), gap[:3]))
    tag = "OK" if not (errs or stale or dupes or below) else "!!"
    print("  [%s] %-5s %3d/%d keys (%.0f%%)%s" % (tag, loc, covered, len(enus_set), pct,
          "" if covered == len(enus_set) else "  (rest fall back to English)"))

# --- hardcoded English (heuristic) ---
hardcoded = scan_hardcoded_english()
if hardcoded:
    shown = "\n      ".join(hardcoded[:20])
    more = "\n      ... and %d more" % (len(hardcoded) - 20) if len(hardcoded) > 20 else ""
    warn.append("%d possible unlocalized user-facing string(s) -- wrap in L[\"...\"] or annotate "
                "'-- %s':\n      %s%s" % (len(hardcoded), OPT_OUT, shown, more))

print("\n==== RESULT ====")
for e in hard: print("  X HARD:", e)
for w in warn: print("  ! WARN:", w)
if hard:
    print("\n%d hard failure(s)." % len(hard)); sys.exit(1)
print("\nAll locale consistency checks passed.%s" % (" (%d warnings)" % len(warn) if warn else ""))
