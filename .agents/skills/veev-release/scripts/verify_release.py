#!/usr/bin/env python3
"""Verify a published addon release from Git refs through its public zip asset."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")


def veev_root() -> Path:
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "VeevHUD.toc").is_file() and (candidate / ".git").exists():
            return candidate
    raise RuntimeError("Unable to locate the VeevHUD Git root.")


def run(repo: Path, *args: str) -> str:
    result = subprocess.run(
        args,
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"Command failed: {' '.join(args)}: {detail}")
    return result.stdout.strip()


def remote_tag_sha(repo: Path, tag: str) -> str:
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
        raise RuntimeError(f"Remote tag is missing: {tag}")
    rows = [line.split() for line in output.splitlines()]
    peeled = [sha for sha, ref in rows if ref.endswith("^{}")]
    return peeled[0] if peeled else rows[0][0]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", choices=("VeevHUD", "LibSpellDB"))
    parser.add_argument("tag")
    args = parser.parse_args(argv)

    if not TAG_RE.fullmatch(args.tag):
        parser.error("tag must have the form vX.Y.Z")

    root = veev_root()
    contract = json.loads(
        (root / ".agents/skills/veev-release/references/release-contract.json").read_text(
            encoding="utf-8"
        )
    )
    repo = root if args.repository == "VeevHUD" else root.parent / "LibSpellDB"
    expected = contract["repositories"][args.repository]
    slug_match = re.search(r"github\.com/([^/]+/[^/]+?)(?:\.git)?$", expected["origin"])
    if not slug_match:
        raise RuntimeError("Release contract contains an invalid GitHub origin.")
    slug = slug_match.group(1)

    try:
        run(repo, "git", "fetch", "origin", expected["branch"], "--tags")
        local_tag_sha = run(repo, "git", "rev-list", "-n", "1", args.tag)
        remote_sha = remote_tag_sha(repo, args.tag)
        branch_sha = run(repo, "git", "rev-parse", f"origin/{expected['branch']}")
        head_sha = run(repo, "git", "rev-parse", "HEAD")
        if len({local_tag_sha.lower(), remote_sha.lower(), branch_sha.lower(), head_sha.lower()}) != 1:
            raise RuntimeError("Local tag, remote tag, release branch, and HEAD do not resolve to one commit.")
        if run(repo, "git", "status", "--porcelain"):
            raise RuntimeError("Worktree is not clean after release.")

        release = json.loads(
            run(
                repo,
                "gh",
                "release",
                "view",
                args.tag,
                "--repo",
                slug,
                "--json",
                "assets,isDraft,isPrerelease,tagName,url",
            )
        )
        if release["isDraft"] or release["isPrerelease"] or release["tagName"] != args.tag:
            raise RuntimeError("GitHub release is not a final public release for the expected tag.")
        zip_assets = [asset["name"] for asset in release["assets"] if asset["name"].endswith(".zip")]
        expected_asset = f"{args.repository}-{args.tag}.zip"
        if zip_assets != [expected_asset]:
            raise RuntimeError(
                f"Expected one release asset named {expected_asset}; found {zip_assets or 'none'}."
            )

        with tempfile.TemporaryDirectory(prefix="veev-release-verify-") as temp_dir:
            run(
                repo,
                "gh",
                "release",
                "download",
                args.tag,
                "--repo",
                slug,
                "--pattern",
                "*.zip",
                "--dir",
                temp_dir,
            )
            checker = root / "Tools/check_package_contents.py"
            result = subprocess.run(
                [
                    sys.executable,
                    str(checker),
                    temp_dir,
                    "--addon",
                    args.repository,
                    "--source-root",
                    str(repo),
                    "--expected-version",
                    args.tag.removeprefix("v"),
                ],
                cwd=root,
                text=True,
                check=False,
            )
            if result.returncode:
                raise RuntimeError("Published archive verification failed.")

        print(f"Release verified: {args.repository} {args.tag}")
        print(f"Commit: {local_tag_sha}")
        print(f"Release: {release['url']}")
        return 0
    except (RuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"Release verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
