# BMAD Model Selection Reference

Which Claude model and thinking effort to use for each BMAD command.

## Models

| Model | ID | $/1M (in/out) | Best at |
|---|---|---|---|
| **Fable 5** | `claude-fable-5` | $10 / $50 | Hardest reasoning, long-horizon autonomous runs, first-shot whole-system builds, deep multi-file review |
| **Opus 4.8** | `claude-opus-4-8` | $5 / $25 | Strong default for everything demanding — architecture, complex dev, bug-finding/review, knowledge work, writing |
| **Sonnet 4.6** | `claude-sonnet-4-6` | $3 / $15 | Speed/cost balance — routine dev, story drafting, high-volume passes |
| **Haiku 4.5** | `claude-haiku-4-5` | $1 / $5 | Cheap/fast mechanical tasks — status, indexing, sharding |

## BMAD command → model → effort

| BMAD command | Model | Effort |
|---|---|---|
| `bmad-agent-analyst` (Mary) | Opus 4.8 | high |
| `bmad-agent-pm` / `bmad-prd` / `bmad-create-prd` | Opus 4.8 | high |
| `bmad-product-brief` / `bmad-prfaq` | Opus 4.8 | high |
| `bmad-agent-architect` / `bmad-create-architecture` | Opus 4.8 (Fable 5 if huge/novel) | xhigh |
| `bmad-create-epics-and-stories` | Opus 4.8 | high |
| `bmad-create-story` / `bmad-create-tech-spec` | Sonnet 4.6 | medium |
| `bmad-agent-ux-designer` / `bmad-ux` | Opus 4.8 | high |
| `*-research` / `deep-research` | Opus 4.8 (Fable 5 deepest) | high → xhigh |
| `bmad-brainstorming` / `bmad-party-mode` | Sonnet 4.6 | medium |
| **`bmad-agent-dev` (Amelia) / `bmad-dev-story`** | **Opus 4.8** | **xhigh** |
| `bmad-quick-dev` / `bmad-quick-flow-solo-dev` | Sonnet 4.6 | medium |
| Long autonomous / overnight builds | **Fable 5** | high |
| `bmad-correct-course` | Opus 4.8 | high |
| **`bmad-code-review` / `code-review`** | **Opus 4.8** (Fable 5 for ultra/multi-agent) | **xhigh** |
| `bmad-review-adversarial-general` | Opus 4.8 → Fable 5 | xhigh |
| `bmad-review-edge-case-hunter` | Opus 4.8 | high |
| `bmad-check-implementation-readiness` | Opus 4.8 | high |
| `bmad-investigate` | Opus 4.8 (Fable 5 deep traces) | xhigh |
| `bmad-qa-generate-e2e-tests` / `testarch-*` | Sonnet 4.6 (Opus 4.8 for test design/NFR) | medium |
| `bmad-agent-tech-writer` / `bmad-document-project` | Opus 4.8 | high |
| `bmad-editorial-review-prose` / `-structure` | Opus 4.8 | high |
| `bmad-generate-project-context` | Sonnet 4.6 | medium |
| `bmad-sprint-status` / `bmad-sprint-planning` | Haiku 4.5 | low |
| `bmad-index-docs` / `bmad-shard-doc` | Haiku 4.5 | low |
| `bmad-retrospective` / `bmad-help` | Sonnet 4.6 | medium |
| `bmad-advanced-elicitation` | Sonnet 4.6 | medium |

## Effort & thinking notes

- **Effort levels:** `low` < `medium` < `high` < `xhigh` < `max`. `xhigh`/`max` are Opus-4.7+/Fable only — **not** on Haiku (errors). Set via `output_config: {effort: "..."}` (not top-level).
- **Thinking:** Opus 4.8 / Sonnet 4.6 / Haiku 4.5 use `thinking: {type: "adaptive"}`. `budget_tokens` is removed on Opus 4.8/Fable (400).
- **Fable 5:** thinking is always on — omit the `thinking` param entirely (`{type: "disabled"}` returns 400). Lower effort still beats prior models' `max`, so sweep down for routine work.
- **Rule of thumb:** default to Opus 4.8 at `high`; raise to `xhigh` for coding/long-horizon agentic; reach for Fable 5 only on your hardest tasks; drop to Sonnet/Haiku for high-volume or mechanical chores.
- **Review tip:** prompt the model to report everything and filter downstream — Opus 4.8/Fable follow "only high-severity" instructions literally, which can hide findings.
