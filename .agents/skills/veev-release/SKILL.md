---
name: veev-release
description: Coordinate production releases of LibSpellDB and VeevHUD. Use only when the user explicitly invokes /veev-release or $veev-release in the current prompt. Do not use for ordinary implementation, changelog drafting, version questions, cleanup, or requests that merely mention releasing. Handles coordinated versioning, validation, changelogs, commits, branch CI, tags, publishing, and artifact verification across both addon repositories.
---

# Coordinated Addon Release

Release LibSpellDB before VeevHUD when both have unreleased changes. VeevHUD
consumes LibSpellDB as a packaged external, so include newly shipped library
changes in VeevHUD's player-facing changelog.

## Authority

Do not commit, push, edit release changelogs, bump versions, create tags, or
publish unless the user explicitly invokes `/veev-release` or `$veev-release`
in the current prompt. Requests to fix, prepare, review, or recommend a release
do not grant release authority.

This workflow is the only authority to:

- write release entries in `CHANGELOG.md`;
- change `## Version:` in addon TOC files;
- increment LibSpellDB's LibStub `MINOR`;
- commit, push, tag, or publish either addon.

During normal development, do not create an Unreleased section or change
release metadata. Once a version tag is pushed, never amend its commit, delete
and recreate it, or force-push a correction. Ship corrections in a new version.

## Repositories And Portability

Work from the VeevHUD Git root. Resolve it with `git rev-parse --show-toplevel`
rather than a machine-specific path. Resolve LibSpellDB as the sibling
`../LibSpellDB` repository. Stop if either repository is missing when needed.

Expected origins:

- VeevHUD: `https://github.com/veev-code/VeevHUD.git`
- LibSpellDB: `https://github.com/veev-code/LibSpellDB.git`

The expected release branch for both repositories is `master`.

The repositories are independent. Never stage one repository from the other.
Use PowerShell-compatible commands locally, do not chain with `&&`, and do not
pipe Git output through `Select-Object`.

## Security And Package Boundary

- Never print, copy, stage, or commit credential values, `.env` files, local
  Claude settings, WoW `WTF`/SavedVariables data, debug logs, or temporary
  release credentials.
- Refer to GitHub Actions secrets only by their configured names.
- `.agents/` and `.claude/` are source-only agent tooling. They must remain in
  `.pkgmeta`'s ignore list and must never appear in addon archives.
- Require the owning repository's package-boundary check to pass before
  treating release validation as green. VeevHUD uses
  `Tools/check_package_contents.py`; LibSpellDB performs the equivalent archive
  inspection in its release workflow.

## Release Contract And Helpers

Treat
`.agents/skills/veev-release/references/release-contract.json` as the canonical
machine-readable release contract. It contains only public repository metadata
and immutable release identifiers. Keep it synchronized with `.pkgmeta`.

Use the source-only helpers instead of recreating mechanical checks:

```text
python .agents/skills/veev-release/scripts/preflight.py
python .agents/skills/veev-release/scripts/verify_release.py <VeevHUD|LibSpellDB> <vX.Y.Z>
```

The preflight is read-only. It validates repository identity, branches, version
consistency, tag availability, active workflows, and the embedded LibSpellDB
pin. The verifier checks local and remote refs, the public GitHub release,
archive structure, source-only exclusions, versions, the LibStub minor, the
embedded dependency contract, and the archive SHA-256.

VeevHUD must pin LibSpellDB by full commit SHA in `.pkgmeta`. After publishing
a new LibSpellDB version, update both `.pkgmeta` and the release contract with
the verified tag, full commit SHA, version, and LibStub minor before preparing
VeevHUD. Never package LibSpellDB from an unpinned branch head.

## Mandatory Preflight

Run the preflight helper before editing release files, then review its findings
with the following judgment checks for both repositories:

1. Read the TOC and changelog.
2. Review `git status --short`, the active branch, and origin reported by the
   helper.
3. Require the intended release branch and expected origin.
4. Get version tags with `git tag --sort=-v:refname`.
5. Review every uncommitted change and commit since the newest tag.
6. Review the recent workflow history in addition to the helper's active-run
   gate.
7. Determine the next unused patch version and verify both local and remote tag
   absence with `git show-ref` and `git ls-remote --tags origin`.
8. Stop on ambiguous scope, red validation, an overlapping release, or unrelated
   dirty changes that cannot be staged separately.

Write changelog entries from the complete release delta, not session notes.

## Release LibSpellDB

If LibSpellDB has neither uncommitted changes nor commits after its newest tag,
report that no library release is needed and continue.

When it has releasable work:

1. Review the complete delta.
2. Bump `LibSpellDB.toc` to the next patch version.
3. Increment the numeric LibStub `MINOR` in `Core/LibSpellDB.lua`.
4. Add one changelog entry covering every shipped API, schema, and spell-data
   change.
5. Run `python Tools/validate_spells.py`, Lua syntax validation, and relevant
   targeted checks.
6. Verify the TOC version and LibStub minor with `rg`.
7. Stage only intended files. Use `git add -A` only when every dirty file has
   been reviewed and belongs to the release.
8. Inspect `git diff --cached --check`, `git diff --cached --stat`, and the full
   cached diff. Stop if version, minor, changelog, or implementation files are
   missing.
9. Commit and push the release branch.
10. Find and watch the branch workflow for the exact commit SHA. Do not create
    the tag until branch CI succeeds.
11. Create the unused `v*` tag, push it, and watch the tag workflow with
    `gh run watch <run-id> --exit-status`.
12. Run `verify_release.py LibSpellDB <tag>` to verify the published GitHub
    release, archive asset, remote tag SHA, checksum, and clean synchronized
    worktree.
13. Before preparing VeevHUD, pin the verified full LibSpellDB commit in
    VeevHUD's `.pkgmeta` and update `release-contract.json`. Confirm the pinned
    version, tag, commit, and LibStub minor all describe the same release.

## Release VeevHUD

Release VeevHUD when it has unreleased work or when a new LibSpellDB release
must be pulled into the packaged external.

1. Review the complete VeevHUD delta and LibSpellDB changes shipped since the
   previous VeevHUD release.
2. Bump `VeevHUD.toc` to the next patch version.
3. Add a player-facing changelog entry. Include `LibSpellDB Updates` only when
   library changes are newly included.
4. Run `python Tools/check_locales.py`, Lua syntax validation, relevant targeted
   checks, and `python Tools/check_package_contents.py <package-path> --addon
   VeevHUD --source-root .` after a dry package build.
5. Review `TODO.md`. Move only fully completed items to Implemented with the
   new version and preserve reporter credits.
6. Verify the TOC version with `rg`.
7. Stage only intended files and inspect the complete cached diff. Stop if the
   TOC, changelog, intended implementation, or required TODO changes are absent.
8. Commit and push the release branch.
9. Find and watch the branch workflow for the exact commit SHA. Do not tag
   until branch CI succeeds.
10. Create and push the unused `v*` tag, then watch the tag workflow through
    package publication and notification.
11. Run `verify_release.py VeevHUD <tag>`. Require the expected public zip,
    matching refs and versions, pinned embedded LibSpellDB version and minor,
    archive checksum, and a clean synchronized worktree.

## Resume And Failure Rules

Reconcile Git and GitHub state before resuming an interrupted release. Continue
from a verified checkpoint; do not repeat completed mutations.

- Branch commit pushed, tag absent: find exact-SHA branch CI and continue only
  after it succeeds.
- Tag present, workflow queued or running: watch the existing workflow. Do not
  create another tag or dispatch a competing release.
- Tag present, workflow failed before producing a valid artifact: distinguish a
  retryable infrastructure or credential failure from a bad release commit.
  Rerun the existing workflow only when doing so cannot change release content.
- Published artifact incorrect or release commit defective: never move or
  recreate the tag. Prepare a new patch release.
- LibSpellDB published but VeevHUD incomplete: keep the library release, update
  the VeevHUD dependency contract to that verified release, and resume only the
  VeevHUD phases.
- Local state disagrees with remote state: stop and report the exact mismatch.
  Never force-push or delete remote release refs.

The release workflows must accept only semantic `v*.*.*` tags, serialize
release jobs without canceling an in-progress publication, pin third-party
actions by immutable commit SHA, validate the package contract before tagging,
and send success announcements only after every required release step passes.

## Changelog Rules

### VeevHUD

Describe what players notice relative to the prior release. Omit refactors and
intermediate fixes to features introduced within the same release.

Preserve specific reporter/requester credit:

- feature: `*(Username)*`
- bug: `*(Thanks Username for reporting)*`

When LibSpellDB changed, use:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added/Changed/Fixed
- Player-facing VeevHUD changes.

### LibSpellDB Updates
- Library changes visible to VeevHUD users.
```

### LibSpellDB

Technical detail is appropriate. Document API and schema changes, new or
corrected spell data, deprecations, and breaking changes for consumers.

## Final Report

Report:

- released addons, versions, commit SHAs, and tags;
- branch push, branch CI, tag workflow, and GitHub release results;
- LibSpellDB changes included in VeevHUD's changelog;
- TODO items moved to Implemented;
- package-boundary verification;
- embedded LibSpellDB version, tag, full commit SHA, and LibStub minor;
- published archive name and SHA-256;
- remaining validation or post-release follow-up.
