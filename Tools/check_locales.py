#!/usr/bin/env python3
"""Locale consistency checker for VeevHUD (AceLocale-3.0).

Why this exists: VeevHUD keys every string by its English text (L["English"]).
That's readable and contributor-friendly, but it means editing an English string
in code/enUS leaves the OLD text as a now-orphaned key in every translation file
(which then silently falls back to English). This script makes that — and any
placeholder/color-code damage — loud instead of silent.

Checks (HARD = exit 1, blocks CI; WARN = reported, non-blocking):
  HARD  every L["..."] used in code is defined in enUS.lua   (else AceLocale errors)
  HARD  every locale line is a valid L["k"] = true|"v" assignment (structural)
  HARD  no "stale" keys: a translation key not present in enUS
        (the signal that English changed and that translation needs updating)
  HARD  %s / %d format-specifier multiset matches between key and value
        (a missing/extra %s in a :format() string is a runtime error)
  HARD  |cff..|r color-code counts match between key and value
  WARN  translation coverage (untranslated keys just fall back to English)
  WARN  enUS keys not referenced anywhere in code (dead entries)

Run locally:  python3 Tools/check_locales.py
Runs in CI on every push/PR (see .github/workflows/release.yml).
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCALES = ROOT / "Locales"

STR = r'(?:\\.|[^"\\])*'                      # Lua double-quoted body (escape-aware)
KEY_USE_RE = re.compile(r'\bL\["(' + STR + r')"\]')
ENUS_RE = re.compile(r'^L\["(' + STR + r')"\]\s*=\s*true\s*$')
TR_RE   = re.compile(r'^L\["(' + STR + r')"\]\s*=\s*"(' + STR + r')"\s*$')
FMT_RE  = re.compile(r'%\d*\.?\d*[sdfgxXq%]')  # real format specifiers (not literal "100%")
COLOR_OPEN_RE = re.compile(r'\|c[fF][fF][0-9a-fA-F]{6}')

hard, warn = [], []

def parse_locale(path, is_default):
    """Parse a Locales/*.lua into {key: value}; collect structural errors."""
    kv, errs, in_block = {}, [], False
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
        kv[m.group(1)] = True if is_default else m.group(2)
    return kv, errs

def scan_code_keys():
    keys = set()
    for p in ROOT.rglob("*.lua"):
        rel = p.relative_to(ROOT)
        # Only addon-owned runtime Lua is relevant. Generated packages contain
        # embedded AceLocale consumers, and source tooling can contain Lua
        # snippets; treating either as VeevHUD code creates false failures.
        if set(rel.parts) & {
            ".agents", ".claude", ".git", ".github", ".release",
            "Libs", "Locales", "Tools",
        }:
            continue
        for m in KEY_USE_RE.finditer(p.read_text(encoding="utf-8")):
            keys.add(m.group(1))
    return keys

# --- enUS (source of truth) ---
enus_path = LOCALES / "enUS.lua"
if not enus_path.exists():
    print("FATAL: Locales/enUS.lua not found"); sys.exit(2)
enus, enus_errs = parse_locale(enus_path, True)
enus_set = set(enus)
for n, line in enus_errs:
    hard.append("enUS.lua:%d unparseable line: %s" % (n, line))

# --- code vs enUS ---
code_keys = scan_code_keys()
missing = code_keys - enus_set
if missing:
    for k in sorted(missing)[:10]:
        hard.append("code uses L[%r] but enUS.lua does not define it (AceLocale will error)" % k)
unused = enus_set - code_keys
if unused:
    warn.append("%d enUS keys defined but never used in code, e.g. %r" % (len(unused), sorted(unused)[:3]))

# --- each translation ---
locale_files = sorted(p for p in LOCALES.glob("*.lua") if p.stem != "enUS")
print("enUS source keys: %d | translations: %d\n" % (len(enus_set), len(locale_files)))
for path in locale_files:
    loc = path.stem
    kv, errs = parse_locale(path, False)
    for n, line in errs:
        hard.append("%s:%d unparseable line: %s" % (path.name, n, line))
    stale = sorted(set(kv) - enus_set)
    for k in stale[:10]:
        hard.append("%s: stale key not in enUS (English changed? remove or re-key): %r" % (loc, k))
    for k, v in kv.items():
        if k not in enus_set:
            continue
        if sorted(FMT_RE.findall(k)) != sorted(FMT_RE.findall(v)):
            hard.append("%s: format specifiers differ for %r -> %r" % (loc, k[:40], v[:50]))
        if (len(COLOR_OPEN_RE.findall(k)), k.count("|r")) != (len(COLOR_OPEN_RE.findall(v)), v.count("|r")):
            hard.append("%s: color-code counts differ for %r" % (loc, k[:40]))
    covered = len(set(kv) & enus_set)
    pct = 100.0 * covered / max(1, len(enus_set))
    tag = "OK" if not (errs or stale) else "!!"
    print("  [%s] %-5s %3d/%d keys (%.0f%%)%s" % (tag, loc, covered, len(enus_set), pct,
          "" if covered == len(enus_set) else "  (rest fall back to English)"))

print("\n==== RESULT ====")
for e in hard: print("  X HARD:", e)
for w in warn: print("  ! WARN:", w)
if hard:
    print("\n%d hard failure(s)." % len(hard)); sys.exit(1)
print("\nAll locale consistency checks passed.%s" % (" (%d warnings)" % len(warn) if warn else ""))
