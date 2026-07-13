#!/usr/bin/env python3
"""Validate addon archive structure, versions, dependencies, and source-only exclusions."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile


BLOCKED_DIRECTORIES = {".agents", ".claude", ".git", ".github"}
BLOCKED_FILES = {
    ".gitignore",
    "agents.md",
    "claude.md",
    "skill.md",
    "todo.md",
}
TOC_VERSION_RE = re.compile(r"^## Version:\s*(\S+)\s*$", re.MULTILINE)
LIB_MINOR_RE = re.compile(r'local MAJOR, MINOR = "LibSpellDB-1\.0",\s*(\d+)')
PIN_RE = re.compile(
    r"(?ms)^\s{2}Libs/LibSpellDB:\s*$.*?^\s{4}commit:\s*([0-9a-fA-F]{40})\s*$"
)


def normalized_parts(archive_path: str) -> tuple[str, ...]:
    return PurePosixPath(archive_path.replace("\\", "/")).parts


def is_blocked(archive_path: str) -> bool:
    parts = normalized_parts(archive_path)
    folded = tuple(part.casefold() for part in parts)
    return (
        bool(BLOCKED_DIRECTORIES.intersection(folded))
        or (bool(folded) and folded[-1] in BLOCKED_FILES)
        or (len(folded) >= 2 and folded[1] == "tools")
        or (len(folded) == 2 and folded[-1] == "readme.md")
    )


def find_archives(inputs: list[str]) -> list[Path]:
    archives: list[Path] = []
    for raw_path in inputs:
        path = Path(raw_path)
        if path.is_file() and path.suffix.lower() == ".zip":
            archives.append(path)
        elif path.is_dir():
            archives.extend(sorted(path.rglob("*.zip")))
        else:
            raise FileNotFoundError(f"Package path not found: {path}")
    return sorted(set(archives))


def read_text(package: ZipFile, name: str) -> str:
    return package.read(name).decode("utf-8-sig")


def parse_toc_version(text: str, label: str) -> str:
    match = TOC_VERSION_RE.search(text)
    if not match:
        raise ValueError(f"No Version metadata found in {label}.")
    return match.group(1)


def source_version(source_root: Path, addon: str) -> str:
    return parse_toc_version(
        (source_root / f"{addon}.toc").read_text(encoding="utf-8-sig"),
        f"source {addon}.toc",
    )


def source_lib_minor(source_root: Path) -> int:
    match = LIB_MINOR_RE.search(
        (source_root / "Core/LibSpellDB.lua").read_text(encoding="utf-8")
    )
    if not match:
        raise ValueError("No LibSpellDB LibStub minor found in source.")
    return int(match.group(1))


def load_dependency_contract(source_root: Path) -> dict[str, object]:
    contract_path = (
        source_root
        / ".agents/skills/veev-release/references/release-contract.json"
    )
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    dependency = contract["embedded_dependencies"]["LibSpellDB"]
    pkgmeta = (source_root / ".pkgmeta").read_text(encoding="utf-8")
    pin_match = PIN_RE.search(pkgmeta)
    if not pin_match or pin_match.group(1).lower() != str(dependency["commit"]).lower():
        raise ValueError("LibSpellDB .pkgmeta pin does not match the release contract.")
    return dependency


def validate_archive(
    archive: Path,
    addon: str | None,
    source_root: Path,
    expected_version: str | None,
) -> list[str]:
    errors: list[str] = []
    with ZipFile(archive) as package:
        names = [name for name in package.namelist() if not name.endswith("/")]
        blocked = sorted(name for name in names if is_blocked(name))
        if blocked:
            errors.extend(f"source-only entry is packaged: {name}" for name in blocked)

        unsafe = [
            name
            for name in names
            if not normalized_parts(name)
            or ".." in normalized_parts(name)
            or name.startswith(("/", "\\"))
        ]
        errors.extend(f"unsafe archive path: {name}" for name in unsafe)

        if addon is None:
            return errors

        roots = {normalized_parts(name)[0] for name in names if normalized_parts(name)}
        if roots != {addon}:
            errors.append(f"expected only the {addon} archive root, found: {sorted(roots)}")

        toc_name = f"{addon}/{addon}.toc"
        if toc_name not in names:
            errors.append(f"required file is missing: {toc_name}")
            return errors

        archive_version = parse_toc_version(read_text(package, toc_name), toc_name)
        target_version = expected_version or source_version(source_root, addon)
        if archive_version != target_version:
            errors.append(
                f"archive version {archive_version} does not match expected {target_version}"
            )

        changelog = (source_root / "CHANGELOG.md").read_text(encoding="utf-8-sig")
        if f"## [{target_version}]" not in changelog:
            errors.append(f"source changelog has no entry for {target_version}")

        if addon == "LibSpellDB":
            core_name = "LibSpellDB/Core/LibSpellDB.lua"
            if core_name not in names:
                errors.append(f"required file is missing: {core_name}")
            else:
                minor_match = LIB_MINOR_RE.search(read_text(package, core_name))
                expected_minor = source_lib_minor(source_root)
                if not minor_match or int(minor_match.group(1)) != expected_minor:
                    errors.append(
                        f"archive LibStub minor does not match expected {expected_minor}"
                    )

        if addon == "VeevHUD":
            dependency = load_dependency_contract(source_root)
            lib_toc = "VeevHUD/Libs/LibSpellDB/LibSpellDB.toc"
            lib_core = "VeevHUD/Libs/LibSpellDB/Core/LibSpellDB.lua"
            if lib_toc not in names:
                errors.append(f"embedded dependency file is missing: {lib_toc}")
            elif parse_toc_version(read_text(package, lib_toc), lib_toc) != dependency["version"]:
                errors.append(
                    "embedded LibSpellDB version does not match the release contract"
                )
            if lib_core not in names:
                errors.append(f"embedded dependency file is missing: {lib_core}")
            else:
                minor_match = LIB_MINOR_RE.search(read_text(package, lib_core))
                if not minor_match or int(minor_match.group(1)) != dependency["minor"]:
                    errors.append(
                        "embedded LibSpellDB minor does not match the release contract"
                    )
    return errors


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", help="Zip archives or directories containing them.")
    parser.add_argument("--addon", choices=("VeevHUD", "LibSpellDB"))
    parser.add_argument("--source-root", default=".")
    parser.add_argument("--expected-version")
    args = parser.parse_args(argv)

    try:
        archives = find_archives(args.inputs)
    except FileNotFoundError as error:
        print(error, file=sys.stderr)
        return 1
    if not archives:
        print("No package zip archives found.", file=sys.stderr)
        return 1

    failures: list[tuple[Path, list[str]]] = []
    for archive in archives:
        try:
            errors = validate_archive(
                archive,
                args.addon,
                Path(args.source_root).resolve(),
                args.expected_version,
            )
        except (BadZipFile, KeyError, OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
            errors = [str(error)]
        if errors:
            failures.append((archive, errors))
        else:
            print(f"Package OK: {archive.name} sha256={sha256(archive)}")

    if failures:
        for archive, errors in failures:
            print(f"Package validation failed for {archive}:", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
        return 1

    print(f"Package boundary and release contract OK: checked {len(archives)} archive(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
