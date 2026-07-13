# VeevHUD Agent Instructions

Repo-local reusable workflows live in `.agents/skills/<skill>/SKILL.md`. Every
VeevHUD or LibSpellDB skill hosted here must use the `veev-` prefix.

Claude-compatible entries live in `.claude/skills/<skill>/SKILL.md` and are
lightweight pointers to the canonical `.agents` workflow. Do not duplicate
workflow bodies in compatibility shims.

When the user explicitly invokes `/veev-release` or `$veev-release`, read and
follow `.agents/skills/veev-release/SKILL.md`, including in tools that do not
natively resolve skill invocations.

Release authority is explicit-only. Normal development must not edit
`CHANGELOG.md`, bump addon TOC versions, change LibSpellDB's LibStub minor,
commit, push, tag, or publish. Those actions are authorized only by an explicit
`/veev-release` or `$veev-release` invocation in the current prompt.

`VeevHUD/` and the sibling `LibSpellDB/` directory are separate Git
repositories. Preserve unrelated work and validate changes in the repository
that owns them.

Agent tooling is source-only. Keep `.agents/`, `.claude/`, `AGENTS.md`, and
`CLAUDE.md` excluded from packaged addon artifacts, and preserve the CI package
boundary check.
