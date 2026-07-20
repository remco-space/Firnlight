# Project skills (vendored, project-scoped)

These skills are checked into the repo so they apply only to Alpenglow. Claude Code
discovers them at startup — after adding or changing skills here, restart Claude Code
(or `/clear`) to pick them up.

## Provenance

| Skill | Source | License | Notes |
|-------|--------|---------|-------|
| `swiftui-specialist` | Apple, exported from Xcode 27 (`xcrun agent skills export`) | Apple toolchain | Authoritative SwiftUI patterns/perf. |
| `swiftui-whats-new-27` | Apple, exported from Xcode 27 | Apple toolchain | SDK 27 SwiftUI changes (e.g. `@State` → macro). |
| `ui-review-tahoe` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | MIT | macOS UI/UX + HIG-compliance review. |
| `liquid-glass` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | MIT | `.glassEffect()` design language, macOS 27. |

To refresh the Apple skills after an Xcode update, re-run
`xcrun agent skills export` and copy the updated folders over these.
