---
name: sdk-capability-scan
description: >
  Scan the installed Xcode SDK for a framework's capabilities gated to
  Firnlight's OS floor, to check whether a framework skill's pinned content
  (or the absence of any skill) still matches what the SDK actually ships.
  Use before or while working in any framework — whether or not a skill is
  loaded for it — and whenever a task might benefit from a capability the SDK
  gained since the loaded skill (or your own knowledge) was last current.
---

# SDK capability scan

Framework skills — `vision-framework`, `photokit`, and the rest — are pinned
to an upstream release; Apple's own hosted docs lag betas too. Neither is
guaranteed current for a `27+`-targeted app built against beta SDKs. The
installed SDK on disk is the one source of truth that cannot lag: it is
literally what the app compiles against.

## When to run it

For **every** framework the code imports or is about to import — not only
ones with a loaded skill. A framework with *no* skill is the higher-risk
case: nothing else will prompt a check, and CLAUDE.md's "new framework or
platform capability → check for a matching skill" rule has nothing to fire
on until something surfaces the framework in the first place. Also rerun it
mid-task if the work touches a framework you haven't scanned yet, or if a
brief's wording suggests a capability that doesn't sound like something
you've seen in that framework before.

## Running the scan

```bash
scripts/scan-sdk-capabilities.sh <FrameworkName> [minVersion] [platform ...]
```

- `minVersion` defaults to `27` — Firnlight's target floor per CLAUDE.md.
  Pass the project's actual current deployment floor if it differs (check
  `MARKETING_VERSION`'s platform requirement / recent memory before
  assuming — CLAUDE.md's stated target and the shipping deployment target
  have differed before during the 26→27 transition).
- `platform` defaults to `macOS iOS` (both of Firnlight's targets). Add
  `watchOS`/`tvOS`/`visionOS` only if relevant.
- Requires the full Xcode toolchain, not Command Line Tools (same
  `DEVELOPER_DIR` requirement as everything else in CLAUDE.md's Build & run
  section). The script auto-falls-back to the newest `/Applications/Xcode*.app`
  if `xcode-select -p` resolves to the Command Line Tools.

Example:

```bash
scripts/scan-sdk-capabilities.sh Vision
scripts/scan-sdk-capabilities.sh Photos 27 macOS
scripts/scan-sdk-capabilities.sh FoundationModels 27 macOS iOS
```

## Reading the output

This is a **best-effort text scan** (grep/awk over `.swiftinterface` and
headers), not a parser, and it matches the platform's version **exactly** —
it will not find something gated to a later floor than you asked for. Treat
every line as a candidate to read in context, not a certified API list:

- Open the surrounding declaration if a match looks relevant — the scan
  prints a few lines of context but multi-line Swift declarations can run
  longer.
- Cross-check anything you intend to depend on against real behavior
  (build it, run it) before committing to it — beta SDK headers can precede
  working runtime behavior.
- A framework with no skill and interesting scan output is exactly the
  trigger CLAUDE.md's "check that repo for a matching skill" rule describes
  — check upstream (`swift-ios-skills`, `claude-code-apple-skills`) for a
  matching skill before hand-rolling the feature from scratch.

## What this is not

Not a substitute for `swiftui-whats-new-27` (SwiftUI-specific, Apple-curated,
prose explanations) or any framework skill's own content — those explain
*why* and *how*; this only tells you *that something changed* and *where*.
Not a gate that blocks work — a clean scan (nothing found) is a normal,
useful result, not a failure.

## In blind-build

`blind-build`'s standing ground rules already require running this scan for
every framework the code touches, skill or no skill — see that skill for the
exact wording. Report gaps or unskilled frameworks to the orchestrator; never
silently use undocumented capability without saying so.
