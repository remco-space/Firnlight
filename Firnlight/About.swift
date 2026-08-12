import SwiftUI
#if os(macOS)
import AppKit
#endif

/// FR-8.8/FR-8.9: what Firnlight says it is, and which one this is.
///
/// One source for the four facts FR-8.8 lists — name, one sentence, version,
/// copyright — so the Mac's About box and the iPhone/iPad footer cannot drift
/// apart, and so the version can only ever come from the running bundle.
///
/// `version` and `build` are read from `Bundle.main`, never written down in
/// Swift. That is the whole of FR-8.9's "the version shown to the user is
/// always the one actually running": the numbers live in the target's
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` build settings (Xcode
/// stamps them into `Info.plist` as `CFBundleShortVersionString` /
/// `CFBundleVersion` via `GENERATE_INFOPLIST_FILE`), so a build that ships
/// with a stale number is a build that *is* that number — there is no second
/// copy to forget to update. See CLAUDE.md's "Versioning (FR-8.9)" for how the
/// numbers are bumped; build settings cannot carry a comment of their own.
///
/// The copyright names the author as the repository records them (`git log`'s
/// author, matching the `space.remco` bundle identifier), and the year is the
/// year of the first commit — a fact, not a template leftover.
enum AppIdentity {
    /// The name as the bundle knows it, not a string literal: on macOS the
    /// About panel and the Dock read the same key, so a rename can't leave the
    /// two disagreeing. Falls back to the literal only if the key is somehow
    /// absent, which would mean a broken bundle.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Firnlight"
    }

    /// FR-8.8's one sentence. Deliberately the brief's own description of the
    /// app rather than marketing copy: what it does, where it does it.
    static let summary = "Curates desktop wallpapers from your own Photos library, entirely on your device: it finds the nature photos worth showing, learns your taste from quick comparisons, and keeps a Photos album in sync."

    /// `CFBundleShortVersionString` — FR-8.9's major.minor.patch.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// `CFBundleVersion` — the build number that, paired with `version`,
    /// identifies one build and no other (FR-8.9).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// "Version <short> (<build>)", the platform-standard phrasing on both systems.
    static var versionLine: String { "Version \(version) (\(build))" }

    /// FR-8.8's copyright line. Read from the bundle for the same reason as
    /// the version: on macOS the standard About panel takes it from
    /// `NSHumanReadableCopyright` whatever this property does, so having the
    /// iPhone and iPad footer read the same key keeps one truth rather than
    /// two strings that must be kept in step.
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}

#if os(macOS)
/// FR-8.8 *(macOS)*: the About box, filled in.
///
/// The system panel, not a window of our own. `orderFrontStandardAboutPanel`
/// already draws the app's icon, its name, "Version <short> (<build>)" and the
/// copyright from `NSHumanReadableCopyright` — four of FR-8.8's five clauses
/// come free and, more to the point, come from the running bundle, so they
/// cannot be a leftover. Only the one sentence has no Info.plist key, and the
/// panel's `credits` option is where it goes.
///
/// Hence `CommandGroup(replacing: .appInfo)`: the default "About Firnlight"
/// item calls the panel with no options, which would show the sentence only if
/// it were duplicated into a `Credits.rtf` resource — a second copy of a fact,
/// and an RTF file that could carry no explanation of itself. Replacing the
/// item lets the same standard panel be opened with the credits supplied from
/// `AppIdentity`, keeping one source and no custom UI.
///
/// The credits string is `NSAttributedString` because that is what the panel
/// accepts; the font is the system's small label font so the sentence sits in
/// the panel the way a credits line normally does rather than at whatever
/// default an unattributed string would pick.
///
/// `applicationIcon` is passed explicitly, and it is passed
/// `NSApp.applicationIconImage`, for FR-8.8's "the icon shown is the icon".
/// Left to itself the panel resolves `NSImage.applicationIconName`, which goes
/// out to IconServices for a *rendering of* this bundle; the Dock tile is
/// `applicationIconImage`. Those are two paths to the same artwork and they can
/// disagree — observed during development, where IconServices kept serving a
/// months-old composition for the build path (`lsregister -f` did not shift it;
/// the identical bundle copied to a fresh path rendered correctly), so the panel
/// showed the previous icon design while the Dock showed something else again.
/// Handing the panel the very image the Dock draws removes the disagreement
/// by construction — one image, used twice. (What it cannot guarantee is that
/// the image is *fresh*: `applicationIconImage`'s own launch-time value comes
/// from AppKit, and if that ever went stale the panel and the Dock would agree
/// on the same stale icon. Apple documents the Dock tile as downstream of this
/// property, so agreement is the strongest contract on offer.)
/// See `build-and-run.sh` for the cache trap itself, and the one thing that
/// clears it.
struct AboutCommand: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.name)") {
                let credits = NSAttributedString(
                    string: AppIdentity.summary,
                    attributes: [
                        .font: NSFont.preferredFont(forTextStyle: .callout),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                )
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: credits,
                    .applicationIcon: NSApplication.shared.applicationIconImage
                ])
                // The panel opens behind the main window if the app isn't
                // frontmost (e.g. the item was picked from the menu bar while
                // another app had focus).
                NSApplication.shared.activate()
            }
        }
    }
}
#else
/// FR-8.8 *(iPhone and iPad)*: the same facts, where a touch user looks.
///
/// iOS has no About box, and the two candidate "platform's own places" are the
/// Settings app (a `Settings.bundle`) and the foot of the app's own last
/// screen. This is the second, because a `Settings.bundle` can only show
/// *static* strings: its `Root.plist` cannot read `CFBundleShortVersionString`
/// at runtime, so the version there would be a hand-copied literal — exactly
/// the "shown version is always the one actually running" guarantee FR-8.9
/// makes, given up for the sake of the more traditional location.
///
/// It sits at the bottom of the Export tab: the end of the app's journey and
/// its one bounded screen (Library's grid runs to hundreds of thumbnails,
/// and Duel is a focused activity with no scroll at all), which is where the
/// iOS convention of an app-identity footer is legible. It is entirely static —
/// nothing here observes anything — so it can never move a control while the
/// app works (FR-8.7), and it is plain content on the plain background, with
/// no glass of its own (FR-8.5).
///
/// Why this footer shows no icon, when the Mac's About box does.
///
/// FR-8.8 requires that the icon shown *be* the icon — the same rendering
/// the system presents everywhere else, never a second version of it. On
/// the Mac that is satisfiable: `NSApp.applicationIconImage` is the Dock's
/// own image (see `AboutCommand`). On iPhone and iPad there is no such
/// API. What an app can reach is the flattened icon files `actool` baked
/// into the bundle and listed under `CFBundleIcons` — and those are
/// measurably *not* what the Home Screen draws: compared side by side at
/// the same size, the baked file is hazier and lighter, with the glass
/// wash over the near peak much stronger, because SpringBoard composes the
/// Icon Composer layers live rather than blitting that file.
///
/// So the choice is between a slightly-wrong icon and no icon, and the
/// requirement decides it: a second, subtly different version is exactly
/// what it forbids, while the icon is named only in its macOS clause —
/// iPhone and iPad are asked for "the same facts". The four facts are all
/// here. If iOS ever exposes the composed icon, this is where it goes.
struct AboutFooter: View {
    var body: some View {
        // No icon here, deliberately — see the note above the type.
        VStack(spacing: 8) {
            Text(AppIdentity.name)
                .font(.headline)

            Text(AppIdentity.versionLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(AppIdentity.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            Text(AppIdentity.copyright)
                .font(.footnote)
                // `.secondary`, not `.tertiary`: this is a fact the user may
                // have come here to read, the same as the version, so it gets
                // the same contrast rather than being stepped down twice.
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        // One block, one VoiceOver stop: read as the app's identity rather
        // than as five unrelated labels at the end of the album preview.
        .accessibilityElement(children: .combine)
    }
}
#endif
