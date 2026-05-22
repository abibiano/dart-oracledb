---
title: 'Update README and add CONTRIBUTING for pub.dev'
type: 'chore'
created: '2026-05-22'
status: 'done'
route: 'one-shot'
---

## Intent

**Problem:** The README misrepresented the project (implied official Oracle product, listed unimplemented features, claimed only desktop support, contained a non-existent API overload), making it unsuitable for pub.dev users and contributors.

**Approach:** Rewrote README with accurate feature list, platform table, correct API examples (only implemented methods), disclaimer about unofficial status, port origin (node-oracledb), and test coverage info. Created CONTRIBUTING.md as the standard developer-onboarding file.

## Suggested Review Order

1. [README.md — disclaimer and features](../../README.md) — verify unofficial-port framing and platform table
2. [README.md — Quick Start + Queries](../../README.md#quick-start) — check code examples compile against actual API
3. [README.md — Project Status table](../../README.md#project-status) — confirm implemented vs. planned is accurate
4. [CONTRIBUTING.md — integration test setup](../../CONTRIBUTING.md#integration-tests) — docker steps and health check guidance
5. [CONTRIBUTING.md — Adding Protocol Features](../../CONTRIBUTING.md#adding-protocol-features) — submodule init instruction
