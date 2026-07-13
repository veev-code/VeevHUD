#!/usr/bin/env python3
"""Read-only coordinated release preflight for VeevHUD and LibSpellDB."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
TOC_VERSION_RE = re.compile(r"^## Version:\s*(\S+)\s*$", re.MULTILINE)
MINOR_RE = re.compile(r'local MAJOR, MINOR = "LibSpellDB-1\.0",\s*(\d+)')
PIN_RE = re.compile(
    r"(?ms)^\s{2}Libs/LibSpellDB:\s*$.*?^\s{4}commit:\s*([0-9a-fA-F]{40})\s*$"
)
LIB_SOURCE_ONLY_PREFIXES = (".agents/", ".claude/", ".github/", "Tools/")
LIB_SOURCE_ONLY_FILES = {".gitignore", ".pkgmeta", "AGENTS.md", "CLAUDE.md"}


def veev_root() -> Path:
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "VeevHUD.toc").is_file() and (candidate / ".git").exists():
            return candidate
    raise RuntimeError("Unable to locate the VeevHUD Git root.")


def run(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        args,
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"Command failed: {' '.join(args)}: {detail}")
    return result.stdout.strip()


def normalized_origin(value: str) -> str:
    normalized = value.strip().replace("git@github.com:", "https://github.com/")
    return normalized.removesuffix("/").removesuffix(".git").casefold()


def parse_version(value: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"Invalid semantic version: {value}")
    return tuple(int(part) for part in match.groups())


def toc_version(path: Path) -> str:
    match = TOC_VERSION_RE.search(path.read_text(encoding="utf-8-sig"))
    if not match:
        raise ValueError(f"No Version metadata found in {path.name}.")
    return match.group(1)


def remote_tag_sha(repo: Path, tag: str) -> str | None:
    output = run(
        repo,
        "git",
        "ls-remote",
        "--tags",
        "origin",
        f"refs/tags/{tag}",
        f"refs/tags/{tag}^{{}}",
    )
    if not output:
        return None
    rows = [line.split() for line in output.splitlines()]
    peeled = [sha for sha, ref in rows if ref.endswith("^{}")]
    return peeled[0] if peeled else rows[0][0]


def latest_remote_version_tag(repo: Path) -> str | None:
    output = run(repo, "git", "ls-remote", "--tags", "origin", "refs/tags/v*")
    tags = {
        ref.removeprefix("refs/tags/").removesuffix("^{}")
        for _, ref in (line.split() for line in output.splitlines())
    }
    versions = [tag for tag in tags if VERSION_RE.fullmatch(tag)]
    return max(versions, key=parse_version) if versions else None


def active_runs(repo: Path, slug: str) -> list[dict[str, object]]:
    output = run(
        repo,
        "gh",
        "run",
        "list",
        "--repo",
        slug,
        "--workflow",
        "release.yml",
        "--limit",
        "20",
        "--json",
        "databaseId,status,event,headBranch,url",
    )
    return [run_info for run_info in json.loads(output) if run_info["status"] in {"queued", "in_progress"}]


def repository_slug(origin: str) -> str:
    match = re.search(r"github\.com[/:]([^/]+/[^/]+?)(?:\.git)?$", origin)
    if not match:
        raise ValueError("Expected a GitHub origin URL.")
    return match.group(1)


def changed_paths(repo: Path, latest_tag: str) -> list[str]:
    """Return only the current release delta: committed, staged, unstaged, and untracked."""
    paths: set[str] = set()
    commands = (
        ("git", "diff", "--name-only", f"{latest_tag}..HEAD", "--"),
        ("git", "diff", "--name-only", "--cached", "--"),
        ("git", "diff", "--name-only", "--"),
        ("git", "ls-files", "--others", "--exclude-standard"),
    )
    for command in commands:
        output = run(repo, *command)
        paths.update(line for line in output.splitlines() if line)
    return sorted(paths, key=str.casefold)


def is_lib_source_only(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return (
        normalized.startswith(LIB_SOURCE_ONLY_PREFIXES)
        or normalized in LIB_SOURCE_ONLY_FILES
        or normalized.casefold().endswith(".md")
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-remote",
        action="store_true",
        help="Skip GitHub and remote-ref checks; intended only for offline validation.",
    )
    args = parser.parse_args(argv)

    root = veev_root()
    contract_path = root / ".agents/skills/veev-release/references/release-contract.json"
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    repos = {"VeevHUD": root, "LibSpellDB": root.parent / "LibSpellDB"}
    failures: list[str] = []

    for tool in ("git", "gh"):
        if shutil.which(tool) is None and not (tool == "gh" and args.skip_remote):
            failures.append(f"Required command is unavailable: {tool}")

    for name, repo in repos.items():
        print(f"[{name}]")
        expected = contract["repositories"][name]
        if not (repo / ".git").exists():
            failures.append(f"{name}: Git repository is missing.")
            continue
        try:
            actual_root = Path(run(repo, "git", "rev-parse", "--show-toplevel")).resolve()
            if actual_root != repo.resolve():
                failures.append(f"{name}: resolved Git root does not match the expected repository.")

            branch = run(repo, "git", "branch", "--show-current")
            origin = run(repo, "git", "remote", "get-url", "origin")
            if branch != expected["branch"]:
                failures.append(f"{name}: expected branch {expected['branch']}, found {branch or '(detached)'}.")
            if normalized_origin(origin) != normalized_origin(expected["origin"]):
                failures.append(f"{name}: origin does not match the release contract.")

            tags = run(repo, "git", "tag", "--sort=-v:refname").splitlines()
            if not tags:
                failures.append(f"{name}: no version tags found.")
                continue
            latest_tag = tags[0]
            latest_version = ".".join(str(part) for part in parse_version(latest_tag))
            source_version = toc_version(repo / expected["toc"])
            if source_version != latest_version:
                failures.append(
                    f"{name}: TOC version {source_version} does not match latest tag {latest_tag}."
                )
            changelog = (repo / expected["changelog"]).read_text(encoding="utf-8-sig")
            if f"## [{source_version}]" not in changelog:
                failures.append(f"{name}: changelog has no entry for {source_version}.")

            major, minor, patch = parse_version(latest_tag)
            next_tag = f"v{major}.{minor}.{patch + 1}"
            if run(repo, "git", "tag", "--list", next_tag):
                failures.append(f"{name}: candidate tag {next_tag} already exists locally.")
            if not args.skip_remote and remote_tag_sha(repo, next_tag):
                failures.append(f"{name}: candidate tag {next_tag} already exists remotely.")

            dirty = run(repo, "git", "status", "--short")
            delta_paths = changed_paths(repo, latest_tag)
            print(f"  branch={branch} latest={latest_tag} candidate={next_tag}")
            print(f"  worktree={'dirty; review required' if dirty else 'clean'}")
            print(f"  release_delta={len(delta_paths)} path(s)")
            if name == "LibSpellDB" and delta_paths:
                candidates = [path for path in delta_paths if not is_lib_source_only(path)]
                if candidates:
                    print(f"  library_delta=candidate ({len(candidates)} shipped path(s)); review required")
                else:
                    print("  library_delta=none; source-only paths only")

            if not args.skip_remote:
                remote_latest = latest_remote_version_tag(repo)
                if remote_latest != latest_tag:
                    failures.append(
                        f"{name}: latest local tag {latest_tag} does not match remote {remote_latest or '(none)'}."
                    )
                remote_branch = run(repo, "git", "ls-remote", "origin", f"refs/heads/{branch}")
                if not remote_branch:
                    failures.append(f"{name}: remote release branch is missing.")
                slug = repository_slug(expected["origin"])
                runs = active_runs(repo, slug)
                if runs:
                    ids = ", ".join(str(item["databaseId"]) for item in runs)
                    failures.append(f"{name}: active release workflow run(s): {ids}.")
        except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as error:
            failures.append(f"{name}: {error}")

    dependency = contract["embedded_dependencies"]["LibSpellDB"]
    try:
        pkgmeta = (root / ".pkgmeta").read_text(encoding="utf-8")
        pin_match = PIN_RE.search(pkgmeta)
        if not pin_match or pin_match.group(1).lower() != dependency["commit"].lower():
            failures.append("VeevHUD: .pkgmeta LibSpellDB pin does not match the release contract.")

        lib_repo = repos["LibSpellDB"]
        local_sha = run(lib_repo, "git", "rev-list", "-n", "1", dependency["tag"])
        if local_sha.lower() != dependency["commit"].lower():
            failures.append("LibSpellDB: dependency tag does not match the contracted commit.")
        if toc_version(lib_repo / "LibSpellDB.toc") != dependency["version"]:
            failures.append("LibSpellDB: dependency version does not match the current TOC.")
        minor_match = MINOR_RE.search((lib_repo / "Core/LibSpellDB.lua").read_text(encoding="utf-8"))
        if not minor_match or int(minor_match.group(1)) != dependency["minor"]:
            failures.append("LibSpellDB: contracted LibStub minor does not match source.")
        if not args.skip_remote:
            remote_sha = remote_tag_sha(lib_repo, dependency["tag"])
            if remote_sha is None or remote_sha.lower() != dependency["commit"].lower():
                failures.append("LibSpellDB: remote dependency tag does not match the contracted commit.")
    except (RuntimeError, ValueError, OSError) as error:
        failures.append(f"Dependency contract: {error}")

    if failures:
        print("\nPreflight failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("\nRelease preflight passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
