# BMAD × Claude model cheat-sheet (Claude Code)

_Last updated: 2026-06-11 — model facts verified against the `claude-api` skill._

Which model + effort to pick for the three core BMAD implementation workflows:
**create-story** (SM), **dev-story** (DEV), **code-review** (DEV, fresh context).

---

## 1. The model lineup

| Model | Model ID | Context | Max output | Input $/1M | Output $/1M | Built for |
|-------|----------|--------:|-----------:|-----------:|------------:|-----------|
| **Fable 5** | `claude-fable-5` | 1M | 128K | $10.00 | $50.00 | Most capable; long-horizon autonomous agentic work |
| **Opus 4.8** | `claude-opus-4-8` | 1M | 128K | $5.00 | $25.00 | Most capable Opus-tier; autonomous coding, review, knowledge work |
| **Sonnet 4.6** | `claude-sonnet-4-6` | 1M | 64K | $3.00 | $15.00 | Best speed/intelligence balance; high-volume work |
| **Haiku 4.5** | `claude-haiku-4-5` | 200K | 64K | $1.00 | $5.00 | Fast, cheap, simple tasks only |

> Fable 5 is **2× the price of Opus 4.8** ($10/$50 vs $5/$25) — pay it only where its long-horizon endurance actually earns its keep.

---

## 2. "Think modes" = the effort parameter

In Claude Code, thinking depth is the **effort** level. Higher effort → more reasoning, more tool calls, better quality, more tokens/latency.

| Effort | Fable 5 | Opus 4.8 | Sonnet 4.6 | Haiku 4.5 | Use for |
|--------|:------:|:--------:|:----------:|:---------:|---------|
| `low` | ✅ | ✅ | ✅ | ✗ | Mechanical / latency-sensitive |
| `medium` | ✅ | ✅ | ✅ | ✗ | Routine, cost-sensitive |
| `high` | ✅ | ✅ | ✅ | ✗ | Default for intelligence-sensitive work |
| `xhigh` | ✅ | ✅ | ✗ | ✗ | **Best for coding/agentic** (Claude Code default) |
| `max` | ✅ | ✅ | ✅ | ✗ | Correctness > cost |

- **Fable 5 / Opus 4.8** use *adaptive* thinking (Fable's is always-on). No token budgets — control depth with effort.
- **Sonnet 4.6** has no `xhigh` (caps at `high`/`max`). **Haiku 4.5** has no effort parameter at all.
- Claude Code defaults to **`xhigh`** on Opus 4.8/4.7/4.6.

---

## 3. Recommendation matrix

| Workflow | Agent | Recommended | Effort | Why |
|----------|-------|-------------|--------|-----|
| **create-story** | SM | **Sonnet 4.6** | `low`–`medium` | Template-driven doc generation from PRD/arch/epics. Cheap & fast; the template constrains output. |
| **dev-story** | DEV | **Fable 5** (non-trivial) / **Opus 4.8** (well-scoped) | `high`–`xhigh` | Long autonomous implement→test→self-validate loop. Fable's endurance + self-verification; Opus when the story is small. |
| **code-review** | DEV (fresh) | **Opus 4.8** | `high`–`xhigh` | Adversarial bug-hunt, shorter horizon. Use a **different** model than wrote the code. |

### Cost-tuned variants

| Situation | create-story | dev-story | code-review |
|-----------|--------------|-----------|-------------|
| **Quality-critical / hard epic** | Opus 4.8 `high` | Fable 5 `xhigh` | Fable 5 `xhigh` (cross-model from dev) |
| **Budget-conscious** | Sonnet 4.6 `low` | Opus 4.8 `medium`–`high` | Opus 4.8 `high` |
| **Tiny / mechanical story** | Sonnet 4.6 `low` | Opus 4.8 `medium` | Opus 4.8 `medium` |

---

## 4. Rationale

**create-story (SM)** — Structured generation: read PRD, architecture, epics → emit a story file from a template. Deep reasoning rarely pays off here, and the template constrains the output anyway. Sonnet at low/medium keeps your token budget for implementation. Bump to Opus only when a story must reconcile conflicting architecture decisions.

**dev-story (DEV)** — This is where capability matters most: implement tasks, write tests, self-validate against acceptance criteria. Fable 5 investigates before acting and verifies its own work with less prompting — and a well-written story file *is* the "describe the outcome, not the steps" input it's tuned for. Use Fable `high`/`xhigh` for non-trivial stories. For small, well-scoped stories, Opus 4.8 `medium`–`high` is more cost-efficient (Fable is 2× the price and you don't need its endurance for an 8-line change).

**code-review (DEV, fresh context)** — Use Opus 4.8 at `high`/`xhigh`, and deliberately **not** the model that wrote the code — a different model in a fresh chat gives genuinely independent eyes, same logic as not letting the author review their own PR. Opus 4.8 is a stronger bug-finder than 4.7 with clearer explanations, and review is shorter-horizon so Fable's endurance edge doesn't apply. If you implemented with Opus, flip it (Fable reviews Opus's work).

> **Review tip:** models follow "only report high-severity / be conservative" instructions *literally*, which can suppress findings. BMAD's code-review is explicitly adversarial ("NEVER accepts `looks good` — must find minimum issues"), so it already pushes for coverage. Keep that adversarial framing; don't add "only major issues" filters at the find stage.

---

## 5. How BMAD picks the model (it doesn't)

**BMAD Core v6.8.0 has no model knob.** Verified against this install:

- `_bmad/config.toml` agent definitions carry only `module/team/name/title/icon/description` — no `model` field.
- The workflows are Claude Code skills (`bmad-create-story`, `bmad-dev-story`, `bmad-code-review`); their `SKILL.md` frontmatter is just `name` + `description` — no `model`.
- These skills run **in the main conversation**, so they inherit whatever model the Claude Code session is on.

**Consequence:** apply the matrix by setting the session **before** invoking the skill — there is nothing to configure inside BMAD.

| To run... | Do this first |
|-----------|---------------|
| create-story | `/model` → Sonnet 4.6, then `"create the next story"` |
| dev-story | `/model` → Fable 5 (or Opus 4.8 for small stories), then `"dev this story …"` |
| code-review | **New session**, `/model` → a *different* model than dev used, then `"run code review"` |

- Thinking depth follows the effort level (defaults to `xhigh` on Opus).
- `/fast` — Fast Mode: Opus with faster output, no quality downgrade (Opus 4.8/4.7/4.6 only).
- The "different model for review" rule is achieved purely by switching `/model` in the fresh review session — not by any BMAD setting.

> **Power-user caveat:** you *can* pin a model by adding a `model:` line to a skill's `SKILL.md` frontmatter, but that's a Claude Code feature, not BMAD — and `_bmad/custom/config.toml` won't manage it, so a reinstall may overwrite it. Switching `/model` per session is the durable approach.

### Default playbook (one-liner)
> create-story → **Sonnet 4.6 / medium**; dev-story → **Fable 5 / xhigh** (or Opus 4.8 for small stories); code-review → **Opus 4.8 / high, in a fresh session on a different model than dev**.
