# Project skills (project-scoped)

These skills apply only to Alpenglow. Claude Code discovers them at startup —
after adding or changing skills here, restart Claude Code (or `/clear`) to pick
them up.

Two provenance styles are in use, deliberately:

- **Vendored** (plain directories, checked in as-is): a point-in-time copy,
  refreshed by hand when its upstream changes. Used where "auto-update" would
  mean silently swapping in content that hasn't been reviewed (Apple's own
  exports, or a skill whose exact wording this project depends on).
- **Live symlink into a submodule** (`swift-ios-skills-*` rows below): the
  target lives in the `.claude/skills-src/swift-ios-skills` git submodule,
  which `.claude/hooks/skills-submodule-update.sh` fast-forwards to upstream
  on every `SessionStart` (wired via the committed `.claude/settings.json`).
  These stay current with no manual refresh step; if upstream ever ships a
  bad revision, `git -C .claude/skills-src/swift-ios-skills log` shows what
  changed and `git checkout <sha>` in that submodule pins it back.

## Provenance

| Skill | Source | License | Notes |
|-------|--------|---------|-------|
| `swiftui-specialist` | Apple, exported from Xcode 27 (`xcrun agent skills export`) | Apple toolchain | Authoritative SwiftUI patterns/perf. Vendored. |
| `swiftui-whats-new-27` | Apple, exported from Xcode 27 | Apple toolchain | SDK 27 SwiftUI changes (e.g. `@State` → macro). Vendored. |
| `ui-review-tahoe` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | MIT | macOS UI/UX + HIG-compliance review. Vendored. |
| `liquid-glass` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | MIT | `.glassEffect()` design language, macOS 27. Vendored. |
| `photokit` | [dpearson2699/swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills) | see upstream repo | PhotosPicker/PHPhotoLibrary/media permissions — core to the scan/pick pipeline. Auto-updates. |
| `vision-framework` | dpearson2699/swift-ios-skills | see upstream repo | Modern Vision API, relevant to `ImageAnalyzer`. Auto-updates. |
| `swiftdata` | dpearson2699/swift-ios-skills | see upstream repo | `@Model`/`@Query`/migrations. Auto-updates. |
| `swiftui-patterns` | dpearson2699/swift-ios-skills | see upstream repo | `@Observable` ownership, state wiring, view decomposition. Auto-updates. |
| `swiftui-uikit-interop` | dpearson2699/swift-ios-skills | see upstream repo | `UIViewRepresentable`/`UIHostingController` bridging — relevant to the multiplatform (AppKit+UIKit) work. Auto-updates. |
| `background-processing` | dpearson2699/swift-ios-skills | see upstream repo | `BGTaskScheduler` registration/expiration. Auto-updates. |
| `ios-accessibility` | dpearson2699/swift-ios-skills | see upstream repo | VoiceOver/Dynamic Type/focus for the iOS side (complements `ui-review-tahoe`, which is macOS-only). Auto-updates. |
| `ios-localization` | dpearson2699/swift-ios-skills | see upstream repo | String Catalogs, pluralization, RTL. Auto-updates. |
| `swift-concurrency` | dpearson2699/swift-ios-skills | see upstream repo | Sendable/actor isolation, Swift 6 strict concurrency. Auto-updates. |
| `app-store-review` | dpearson2699/swift-ios-skills | see upstream repo | Submission readiness, privacy manifest — relevant once FR-10's manual release process gives way to distribution. Auto-updates. |

To refresh the Apple/HIG-derived vendored skills after an Xcode or upstream
update, re-run `xcrun agent skills export` (Apple) or re-copy from source
(rshankras) over these folders by hand. The `swift-ios-skills`-sourced skills
need no manual step — see the submodule note above.
