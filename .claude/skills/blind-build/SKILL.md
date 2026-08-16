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

**This same test runs again in Phase 4**, on each defect validation finds. A
finding is not automatically a wording gap; some are ordinary bugs against
wording that was already right.

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

Give the orchestrator a `name`, so this session can reach it by `SendMessage`
to start the next round rather than spawning a replacement. Every round it
survives is a round its implementer survives with it (see Phase 3's mechanics);
a loop that has to re-spawn both agents each time keeps paying to rediscover
what the last round already knew.

## Phase 3 — Blind dispatch to the implementer

The orchestrator dispatches an implementer (Agent tool, `model: sonnet`,
`isolation: worktree` — one git actor per worktree). The dispatch contains the
FR reference and the standing ground rules, and **nothing else**.

Mechanics that decide whether Phase 4 can iterate at all: the team roster is
flat, so an orchestrator that was itself given a `name` cannot name its
implementer — omit `name` and spawn it as a plain subagent. An anonymous
subagent is still continuable by ID through `SendMessage`, with its context
intact, **but only by the agent that spawned it**. So the implementer lives
exactly as long as its orchestrator does: the orchestrator must stay alive
across rounds — holding the implementer's ID — or the context is gone and the
branch is all that survives, and "continue the same implementer" degrades to a
fresh agent inheriting a worktree.

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

**The orchestrator never edits code itself** — that rule is absolute, and it is
the one the rest of this phase is built on. But route each defect before
deciding what to do with it, exactly as the Route check does:

- **Wording gap** — the brief permits the wrong outcome, or the orchestrator
  cannot quote a clause the code already violates. Draft the FR amendment whose
  wording would have forced the right outcome and report it to the main
  session; the user approves or edits every amendment before it lands. **Never
  feed such a defect back as a hint**: the wording is what is under test, and a
  hint destroys the measurement for good.
- **Implementation defect** — the orchestrator can quote, verbatim, the clause
  the code already violates. Then blindness has already done its work on that
  clause: the wording won and only the code lost, and there is nothing to
  amend. Send it straight back to the same implementer, naming the defect and
  quoting the clause it breaks. Withholding it measures nothing — it spends a
  round hoping. *(This is where the FR-5.12 undo race stalled: no amendment was
  possible and the loop had no other move.)*

A clause can be quotable **by reference**: FR-8.1 points at Apple's HIG rather
than restating it, so any behaviour the HIG governs is already forbidden, and
the finding is an implementation defect however specific it looks. Never draft
an amendment that restates a rule Apple publishes and maintains — that defeats
the one FR whose job is to keep the brief out of the native-feel checklist
business. Cite FR-8.1, and let the implementer find and follow the guidance it
points at. (CLAUDE.md's rule that native-feel defects ratchet section 8 is for
the class of defect the HIG does *not* cover; a rule already published upstream
is not a missing rule.)

Discipline on the nudge, so it stays a bug report and not a design brief: name
the defect and the clause, never a solution, API, or mechanism — otherwise the
implementer builds the orchestrator's design instead of the brief's. If you
cannot quote the violated clause, it is a wording gap; when in doubt, amend.
Say in the report which findings took which path: amendments are the wording
under test, nudges are the agent under test, and a user who cannot tell them
apart cannot tell whether the brief is improving.

One round routinely produces both kinds, and both continue the **same**
implementer, worktree, and branch. **Iteration is the default; a restart is
the exception** — the branch keeps its history and the agent keeps its context,
and nothing is rebuilt that was already right.

- After an amendment lands, continue that implementer against the amended
  brief. An amended brief is not a hint; it is the artifact under test, and a
  maintainer revisiting old code under new wording is exactly the real-world
  case. That part of the re-dispatch carries what a first dispatch would and
  nothing more: the FR pointers, the new commit, the standing ground rules.
  Never the validation findings behind the amendment, or why the wording
  moved — if the new words cannot redirect the implementer on their own, the
  amendment is not done, and that failure is itself the next finding.
- A routed implementation defect travels in the same message as a plain bug
  report, and does not taint it. Quoting a clause that already passed cannot
  bias a measurement of that clause; there is none left to make.
- Dispatch a **fresh** implementer (Phase 3 from scratch) only when the
  previous one is actually contaminated — intent, rationale, or a wording-gap
  defect reached it — or its worktree/branch state is unsound, or the user asks
  for a clean measurement of the new wording against an unprejudiced reader.
- If the implementer misses a case the brief does not pin down, the wording —
  not the agent — needs another turn. If it misses one the brief does pin down,
  the agent does, and the nudge is how it gets it. If the same build fails on
  capability across rounds with sound wording, surface the Opus escape hatch to
  the user.

## Phase 5 — Landing

Once validation passes: merge `--no-ff` per CLAUDE.md branching rules, bump
the version per FR-8.9, delete the branch. The main session — not the
orchestrator — reports the outcome to the user.
