# Session logs

The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns current goals, acceptance gates and all delivery checkboxes. [NEXT](NEXT.md) is the compact handoff.

## Convention

Create one `YYYY-MM-DD-short-topic.md` per work session; use a suffix if needed. Record purpose/scope, starting branch/commit, exact commands and exit/results, decisions, failures/unresolved limits, resulting commits/reviews, and concrete next steps. Link evidence without embedding long test output. Append findings to the session’s own log; do not append chronology to the main plan. Update NEXT and current plan status after the session. Never convert a failed run into a pass or infer hardware qualification from component tests.

## Index

- [September 25 owned measurement app integration](2026-09-25-owned-measurement-app.md) — native lease, application and retry integration with four-phase preparation.
- [September 25 progressive vertical continuation](2026-09-25-progressive-vertical-resume.md) — paired hardware retry and guarded app application ownership.
- [September 25 three-output vertical](2026-09-25-three-output-vertical.md) — proxy recording, full native simulator route, device lab and physical installation.

- [September 25 guarded SDK](2026-09-25-guarded-sdk.md) — imported checkpoint, `2aa6162`.
- [September 25 guarded adapters](2026-09-25-guarded-adapters.md) — imported checkpoint, `8947c0f`.
- [September 25 guarded Core settlement](2026-09-25-guarded-core.md) — imported checkpoint, `055b0b5`.
- [September 25 guarded PublishingSession](2026-09-25-guarded-session.md) — imported checkpoint, `b65ca7f`; both reviews approved.
- [September 25 plan cleanup](2026-09-25-plan-cleanup.md) — documentation reorganization and handoff.
- [Legacy history, readable](legacy-portable-streaming-plan.md) — older history with unknown session boundaries preserved intact.
- [Original source bytes](legacy-portable-streaming-plan-at-b65ca7f.txt) — lossless snapshot.

## Legacy provenance

Original repository path: `docs/superpowers/plans/2026-09-13-portable-streaming-and-watch.md`.
Source commit: `b65ca7fe1d58be9ac27e88a63c67867d428f1b10` (`codex/local-validation`).
Original line count: 3,206. Original SHA-256: `f8382e9b39359d1355eaa3bad469451ac21576ab0f82cc2c33217b4b60d31fe1`.

The `.txt` file is exactly the original UTF-8 bytes, without an added header. Interpret its relative Markdown links from the original path above; plain `artifacts/`, `ios/`, `scripts/`, and other code-formatted paths are repository-relative. The readable `.md` copy adds only a provenance comment and rebases relative Markdown link destinations to this folder; original prose, failures, checkbox statuses and headings remain. Historical checkpoint anchors live in that readable archive; the live plan contains no checkpoint inventory. No source date or unknown session boundary has been invented; dated headings retain only their original attribution.

The four named September 25 imports come from `docs/superpowers/plans/2026-09-25-owned-application-admission.md` at the same commit, with exact available command arrays imported from local exit records. These are checkpoint extracts, not claims about the start/end of actual sessions. Imported “next” descriptions are contemporaneous; follow NEXT for today’s order.
