# Third-party notices

This repository vendors a small number of Claude Code skill files under
`.claude/skills/`. Their provenance and license are tracked in
[`.claude/skills/README.md`](.claude/skills/README.md); this file carries the
copyright notices their licenses require to travel with the copy.

## `ui-review-tahoe`, `liquid-glass`

Source: [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills),
vendored as a point-in-time copy.

```
MIT License

Copyright (c) 2025 Ravishankar

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## `photokit`, `vision-framework`, `swiftdata`, `swiftui-patterns`,
## `swiftui-uikit-interop`, `background-processing`, `ios-accessibility`,
## `ios-localization`, `swift-concurrency`, `app-store-review`

Source: [dpearson2699/swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills),
pulled in as the `.claude/skills-src/swift-ios-skills` git submodule (not
vendored — cloning this repository with submodules fetches that upstream
repository directly, under its own license).

```
Required Notice: Copyright (c) 2025 dpearson2699 (https://github.com/dpearson2699)

PolyForm Perimeter License 1.0.0
<https://polyformproject.org/licenses/perimeter/1.0.0>
```

The full license text is in that submodule's own `LICENSE` file. It permits
any use except building a competing product; Alpenglow does not compete with
a Claude Code skills collection, so this applies without restriction here.

## `swiftui-specialist`, `swiftui-whats-new-27`

Source: Apple, exported from Xcode 27 via `xcrun agent skills export`, per
[`.claude/skills/README.md`](.claude/skills/README.md). No license or
redistribution terms accompanied this export. **This has not been cleared
for redistribution** — see the open item in the project's compliance
tracking before treating this repository as fully public-safe.
