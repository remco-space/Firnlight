---
name: blind-build
description: >
  Firnlight's workflow for changing what the app does: iterate REQUIREMENTS.md
  with the user, then have uncontaminated agents build and validate from the
  brief alone. Use this for ANY change to user-visible behavior — a new
  feature, a changed behavior, a UX/native-feel defect, "add a requirement",
  "amend the brief", "the app should…" — and for every bug report, because the
  first step decides whether a bug may bypass the loop. Even when the user just
  describes a problem or wish without naming a workflow, load this before
  planning or touching REQUIREMENTS.md or code.
---

# Blind build: requirements first, uncontaminated agents

The brief (`REQUIREMENTS.md`) is the durable artifact; code and agents are
replaceable. Every step below exists to test one thing: **do the brief's own
words force the right outcome?** An implementer that only succeeds when given
hints proves nothing — a future maintainer won't have the hints. A validator
that knows the intent can't tell whether the wording carries it. Blindness is
not ceremony; it is the measurement.

## Route check — is this a bug that bypasses the loop?

Before anything else, read the FRs the report touches and decide:

- **The brief already forbids the behavior** (or it's a crash / data loss) →
  **bug path**: no requirements edit, no blind loop. Branch, fix, verify,
  commit per CLAUDE.md's normal rules. The brief was right; the code disagreed
  with it.
- **The brief is silent or ambiguous about it** → **requirements path** (the
  rest of this skill). The defect is a gap in the brief; fixing only the code
  guarantees the next shape of the same defect. This is how FR-8.7 came to be,
  and it is why native-feel defects feed section 8's ratchet.

When in doubt, it's a requirements change. The bug path is the exception and
must be provable by pointing at the FR the current behavior violates.

## Roles and models

| Role | Model | Why this model |
|------|-------|----------------|
| Brief iteration (main session, with the user) | Fable | Judgment-heavy wording work. |
| Fresh orchestrator — dispatch, blind validation, amendment drafting | Fable | The highest-judgment steps in the loop. |
| Blind implementer | Sonnet | Builds exactly what the brief says; an implementer that "does more than asked" defeats a strictly-scoped blind build. |
| Fan-out helpers (search, diff vetting, adversarial audit) | Sonnet or Haiku | Cheap, bounded tasks. Every teammate may fan these out. |
| Opus | None by default | Escape hatch only: if a build fails repeatedly on *capability* rather than FR wording, the user may escalate one dispatch to Opus. |

## Phase 1 — Iterate the brief with the user

Touch `REQUIREMENTS.md` and nothing else — no code, not even scaffolding.
Drafting rules:

- Write **effect-centric invariants**, not taxonomies of instances. "A control
  only ever moves as the direct result of the user's own act" survives shapes
  no enumeration of spinners and badges anticipated.
- An FR never restates another FR — cross-reference instead. Each FR stands on
  its own.
- Before inventing a house rule, research (subagent) whether a recognized
  published standard already covers it, and anchor the FR there. Only what no
  standard supplies becomes a house rule.
- FRs about public-facing text must themselves demand conciseness.

Loop until the user approves the amended brief. Their approval starts Phase 2.

## Phase 2 — Spawn the fresh orchestrator

**Verify the premise before dispatching anyone.** Read the FR as it actually
stands in `REQUIREMENTS.md`, and take the commit hash from `git log` yourself —
never from the task description, and never from memory. If the brief does not
contain the approved amendment you were told is there, stop and report that;
it is the deliverable. A dispatch that cites wording or a commit you have not
read propagates a false premise to every agent downstream, with all the
authority of the loop behind it.

The orchestrator must not know why the FRs changed, or its validation stops
being a test of the wording. Spawn it via the Agent tool (`model: fable`,
background, this session's context NOT summarized into it). Its prompt is
exactly three things:

1. The FR pointers — numbers and the commit/state of `REQUIREMENTS.md`, never
   the intent, the triggering defect, or the brainstorm's reasoning.
2. The standing ground rules (below).
3. Its instructions: run Phases 3–4 of this skill (tell it to load
   `blind-build`), report validation results and any proposed FR amendments
   back to the main session, and never edit code itself.

## Phase 3 — Blind dispatch to the implementer

The orchestrator dispatches an implementer (Agent tool, `model: sonnet`,
`isolation: worktree` — one git actor per worktree). The dispatch contains the
FR reference and the standing ground rules, and **nothing else**.

Discipline: draft the dispatch, then delete every sentence that is not (a) the
FR reference/commit or (b) a standing ground rule. Cautionary example: an
FR-10.10 dispatch once added "GitHub mobile / narrow viewport" and "the capture
script is yours to extend" — both hints. Every hint transfers information the
FR should carry: a pass no longer proves the wording works, and a miss no
longer reveals which docs under-specify.

**Standing ground rules** (the fixed block, identical in every dispatch —
fixed and content-free about intent, which is why it is not a hint):

- Work on a branch named for the work, in your own worktree. Verify before
  committing; commit per CLAUDE.md; never push.
- Build from `REQUIREMENTS.md` and the code alone. If the brief does not tell
  you enough to build, say so and stop — that finding is the deliverable.
- **Load skills overzealously, and instruct every subagent you spawn to do the
  same.** Before touching any Swift: `swiftui-specialist` and
  `swiftui-whats-new-27`. Entering an area: its framework skill
  (`vision-framework`, `photokit`, `swiftdata`, `swift-concurrency`,
  `swiftui-patterns`, …). Any UI work: `liquid-glass` and the
  `ui-review-tahoe` checklist. Build/run/simulator work: XcodeBuildMCP. Load
  on plausible relevance — do not wait for a trigger to fire on its own.
- **For each framework the code imports or is about to import — whether or
  not a skill is loaded for it — run `sdk-capability-scan`** against the
  deployment target. Pinned skill content lags the SDK, and some frameworks
  have no skill at all; the scan is the only check that fires on the
  unskilled case. Report gaps or unskilled frameworks in your findings; never
  silently build against undocumented capability without saying so.
- Before finishing, re-check that **all** FRs still hold — not just the ones
  you were pointed at — and report any you cannot verify.

## Phase 4 — Blind validation

The orchestrator audits the build against the brief's text alone (fan-out
allowed; have a separate adversarial subagent vet each round's diff). Then:

- **Defects are never fixed in code and never fed back as hints.** For each
  defect, draft the FR amendment whose wording would have forced the right
  outcome, and report it to the main session. The user approves or edits every
  amendment before it lands.
- After the amendment lands, dispatch a **fresh** implementer (Phase 3 again)
  against the amended brief — never the contaminated one.
- If the implementer misses a known case, the wording — not the agent — needs
  another turn. If the same build fails on capability across rounds with sound
  wording, surface the Opus escape hatch to the user.

## Phase 5 — Landing

Once validation passes: merge `--no-ff` per CLAUDE.md branching rules, bump
the version per FR-8.9, delete the branch. The main session — not the
orchestrator — reports the outcome to the user.
