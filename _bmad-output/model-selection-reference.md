# BMAD Model Selection Reference

Which Claude or Codex model and reasoning effort to use for each BMAD command.

## Claude models

| Model | ID | $/1M (in/out) | Best at |
|---|---|---|---|
| **Fable 5** | `claude-fable-5` | $10 / $50 | Hardest reasoning, long-horizon autonomous runs, first-shot whole-system builds, deep multi-file review |
| **Opus 4.8** | `claude-opus-4-8` | $5 / $25 | Strong default for everything demanding — architecture, complex dev, bug-finding/review, knowledge work, writing |
| **Sonnet 4.6** | `claude-sonnet-4-6` | $3 / $15 | Speed/cost balance — routine dev, story drafting, high-volume passes |
| **Haiku 4.5** | `claude-haiku-4-5` | $1 / $5 | Cheap/fast mechanical tasks — status, indexing, sharding |

## Codex models

Codex recommendations reflect the official Codex model-selection guidance fetched on 2026-06-19.

| Model | ID | Best at |
|---|---|---|
| **GPT-5.5** | `gpt-5.5` | Default Codex choice for demanding coding, tool use, research, architecture, review, and long multi-step work |
| **GPT-5.4** | `gpt-5.4` | Strong pinned-workflow option when you need GPT-5.4 specifically |
| **GPT-5.4 mini** | `gpt-5.4-mini` | Faster/lower-cost Codex work: light coding, scans, supporting-doc processing, and subagents |
| **GPT-5.3 Codex Spark** | `gpt-5.3-codex-spark` | ChatGPT Pro research preview for near-instant text-only coding iteration |

## BMAD command → model → effort

| BMAD command | Claude model | Claude effort | Codex model | Codex reasoning |
|---|---|---|---|---|
| `bmad-agent-analyst` (Mary) | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-agent-pm` / `bmad-prd` / `bmad-create-prd` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-product-brief` / `bmad-prfaq` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-agent-architect` / `bmad-create-architecture` | Opus 4.8 (Fable 5 if huge/novel) | xhigh | `gpt-5.5` | xhigh |
| `bmad-create-epics-and-stories` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-create-story` / `bmad-create-tech-spec` | Sonnet 4.6 | medium | `gpt-5.4-mini` (`gpt-5.5` if ambiguous) | medium |
| `bmad-agent-ux-designer` / `bmad-ux` | Opus 4.8 | high | `gpt-5.5` | high |
| `*-research` / `deep-research` | Opus 4.8 (Fable 5 deepest) | high → xhigh | `gpt-5.5` | high → xhigh |
| `bmad-brainstorming` / `bmad-party-mode` | Sonnet 4.6 | medium | `gpt-5.4-mini` (`gpt-5.5` for strategic sessions) | medium |
| **`bmad-agent-dev` (Amelia) / `bmad-dev-story`** | **Opus 4.8** | **xhigh** | **`gpt-5.5`** | **xhigh** |
| `bmad-quick-dev` / `bmad-quick-flow-solo-dev` | Sonnet 4.6 | medium | `gpt-5.4-mini` (`gpt-5.5` if risky) | medium |
| Long autonomous / overnight builds | **Fable 5** | high | **`gpt-5.5`** | **xhigh** |
| `bmad-correct-course` | Opus 4.8 | high | `gpt-5.5` | high |
| **`bmad-code-review` / `code-review`** | **Opus 4.8** (Fable 5 for ultra/multi-agent) | **xhigh** | **`gpt-5.5`** | **xhigh** |
| `bmad-review-adversarial-general` | Opus 4.8 → Fable 5 | xhigh | `gpt-5.5` | xhigh |
| `bmad-review-edge-case-hunter` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-check-implementation-readiness` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-investigate` | Opus 4.8 (Fable 5 deep traces) | xhigh | `gpt-5.5` | xhigh |
| `bmad-qa-generate-e2e-tests` / `testarch-*` | Sonnet 4.6 (Opus 4.8 for test design/NFR) | medium | `gpt-5.4-mini` (`gpt-5.5` for test design/NFR) | medium → high |
| `bmad-agent-tech-writer` / `bmad-document-project` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-editorial-review-prose` / `-structure` | Opus 4.8 | high | `gpt-5.5` | high |
| `bmad-generate-project-context` | Sonnet 4.6 | medium | `gpt-5.4-mini` | medium |
| `bmad-sprint-status` / `bmad-sprint-planning` | Haiku 4.5 | low | `gpt-5.4-mini` | low |
| `bmad-index-docs` / `bmad-shard-doc` | Haiku 4.5 | low | `gpt-5.4-mini` | low |
| `bmad-retrospective` / `bmad-help` | Sonnet 4.6 | medium | `gpt-5.4-mini` (`gpt-5.5` if strategic) | medium |
| `bmad-advanced-elicitation` | Sonnet 4.6 | medium | `gpt-5.5` | high |

## Effort & thinking notes

- **Claude effort levels:** `low` < `medium` < `high` < `xhigh` < `max`. `xhigh`/`max` are Opus-4.7+/Fable only — **not** on Haiku (errors). Set via `output_config: {effort: "..."}` (not top-level).
- **Thinking:** Opus 4.8 / Sonnet 4.6 / Haiku 4.5 use `thinking: {type: "adaptive"}`. `budget_tokens` is removed on Opus 4.8/Fable (400).
- **Fable 5:** thinking is always on — omit the `thinking` param entirely (`{type: "disabled"}` returns 400). Lower effort still beats prior models' `max`, so sweep down for routine work.
- **Codex reasoning levels:** `minimal` < `low` < `medium` < `high` < `xhigh`. Set with `model_reasoning_effort` in Codex config or agent files.
- **Codex rule of thumb:** start with `gpt-5.5`; use `gpt-5.4-mini` for fast/light/subagent work; use `gpt-5.3-codex-spark` only for near-instant text-only iteration when the research preview is available.
- **Rule of thumb:** default to Opus 4.8 or `gpt-5.5` at `high`; raise to `xhigh` for coding/long-horizon agentic; reach for Fable 5 only on your hardest Claude tasks; drop to Sonnet/Haiku or `gpt-5.4-mini` for high-volume or mechanical chores.
- **Review tip:** prompt the model to report everything and filter downstream — Opus 4.8/Fable follow "only high-severity" instructions literally, which can hide findings.
