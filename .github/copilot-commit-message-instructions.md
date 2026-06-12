# Copilot Commit Message Instructions

Generate commit messages that support this repository's BMAD workflow.

Use Conventional Commits:
- `feat(scope): summary`
- `fix(scope): summary`
- `test(scope): summary`
- `docs(scope): summary`
- `refactor(scope): summary`
- `chore(scope): summary`

Rules:
- Use imperative mood.
- Keep the subject line under 72 characters.
- Summarize the actual staged change, not unrelated repository context.
- Prefer scopes from the touched module or concern, such as `auth`, `connection`, `pool`, `oracledb`, `tests`, `docs`, `ci`, or `build`.
- If the change implements a feature, mention the feature in the summary or body when it is clear from the diff, branch name, or BMAD artifacts.
- When relevant and discoverable, extract epic and story context from `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/implementation-artifacts/sprint-status.yaml`, and the current story/spec file in `_bmad-output/implementation-artifacts/`.
- Mention BMAD epic/story identifiers only when they are explicitly present or can be unambiguously inferred from those artifacts.
- Never invent story IDs, acceptance criteria, validation results, or product claims.
- Add a short body only when the change needs context.
- If a body is useful, prefer concise `Feature:`, `Why:`, and `Validation:` lines.
- Include `Validation:` only when tests, analysis, or manual checks are evident from the diff or user-provided context.
- Do not add AI attribution, `Co-authored-by`, or other trailers unless explicitly requested.

Preferred examples:

```text
feat(pool): add connection pool lifecycle support

Feature: Epic 5 story 5.1, create connection pool
Validation: dart test test/src/pool_test.dart
```

```text
fix(auth): preserve legacy verifier fallback

Why: keeps pre-23c authentication compatible with older servers
```
