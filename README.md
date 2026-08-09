# Alpenglow

Alpenglow curates desktop wallpapers from your own Photos library. It finds
high-resolution nature photos without people, learns your taste from quick
pairwise duels, and maintains a Photos album — "Alpenglow" — that System
Settings can rotate as your wallpaper. Everything runs on-device.

It runs on macOS 27 and, as a companion, on iPhone and iPad on iOS 27. The Mac
is the only place wallpaper actually gets set; on iPhone and iPad, Alpenglow
finds, learns, and curates into the same album, which syncs to the Mac.

See [REQUIREMENTS.md](REQUIREMENTS.md) for exactly what the app does and why.

## Status

Alpenglow is pre-1.0 (see [CHANGELOG.md](CHANGELOG.md) for the current
version) and under active development. Some behaviors are documented as
verified only on specific hardware — see the doc comments at the relevant
call sites for details.

## Installation

Download the latest build from
[Releases](../../releases). There's no App Store distribution and no build
step required.

Because this build isn't signed with a paid Apple Developer account,
Gatekeeper will refuse to open it on first launch ("Apple cannot check it for
malicious software"). To clear that:

- Right-click (or Control-click) the app in Finder and choose **Open**, then
  confirm in the dialog that appears — this only needs to be done once, or
- Run `xattr -cr Alpenglow.app` in Terminal before opening it.

## Usage

Launch the app and grant Photos access when prompted. The three tabs mirror
the pipeline:

1. **Library** — scans your Photos library for wallpaper candidates and
   ranks them.
2. **Duel** — shows you two photos at a time and learns your taste from
   which one you pick.
3. **Export** — maintains the "Alpenglow" Photos album with your top-ranked
   photos. On the Mac, point System Settings → Wallpaper at that album to
   have it rotate automatically.

## Building from source

Requires the full Xcode 27+ toolchain (not just the Command Line Tools):

```bash
git clone --recurse-submodules <this-repo-url>
cd Alpenglow
xcodebuild -project Alpenglow.xcodeproj -scheme Alpenglow -configuration Debug build
```

or just `open Alpenglow.xcodeproj`. See [CLAUDE.md](CLAUDE.md) for the fuller
build, run, and debugging notes (icon rendering, log filtering, simulator
quirks, and so on).

There is no test target — the app's thresholds are tuned by hand against a
real Photos library, and most of its functionality requires interactive
Photos authorization to exercise at all.

## Support

Found a bug or have a feature request? Open an issue on this repository.

## Authors and acknowledgment

Built by [remco.space](https://remco.space). Developed with Claude Code —
see the commit history for co-authorship attribution.

## License

MIT — see [LICENSE](LICENSE).
