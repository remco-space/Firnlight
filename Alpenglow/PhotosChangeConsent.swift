import Foundation
import Observation

/// The kinds of change Alpenglow can make in the user's library, and whether
/// it still asks first (FR-1.9).
///
/// There are exactly two, because `WallpaperAlbumSync` is the app's only write
/// path and it does exactly two things: bring the album into existence, and set
/// what is in it. FR-1.4 forbids everything else, so this list is the complete
/// account of what the app can do to a library — which is what makes a
/// per-kind switch meaningful rather than arbitrary.
///
/// Suppression is per kind, which is FR-1.9's own division: agreeing once that
/// the app may create an album says nothing about it removing photos from one
/// later. Apple's HIG asks the same of a repeating alert — offer the way to
/// stop it in the alert itself, and a way to bring it back in the app's
/// settings — and both halves are here: `SettingsView` reads and writes exactly
/// these switches.
nonisolated enum PhotosChangeKind: String, Sendable {
    /// Creating the wallpaper album (FR-6.11's first-device case).
    case createAlbum
    /// Setting the album's membership: a sync, or putting back what an
    /// interrupted one removed.
    case changeAlbum

    /// How the switch is named in Settings.
    var settingsLabel: String {
        switch self {
        case .createAlbum: "Ask before creating the album"
        case .changeAlbum: "Ask before changing the album"
        }
    }

    var settingsDescription: String {
        switch self {
        case .createAlbum:
            "Alpenglow creates one album, named “\(Thresholds.wallpaperAlbumName)”, and only when you ask it to."
        case .changeAlbum:
            "Adding and removing photos in that album is the only change Alpenglow ever makes in Photos — your photos themselves are never edited or deleted."
        }
    }

    fileprivate var defaultsKey: String { "PhotosChangeConsent.ask.\(rawValue)" }
}

/// One change, named exactly as FR-1.9 requires: what will be created, added,
/// or removed — as counts, before it happens.
nonisolated struct PhotosChange: Sendable, Equatable {
    let kind: PhotosChangeKind
    var added = 0
    var removed = 0
    /// How many photos the album will hold afterwards.
    var total = 0

    var title: String {
        switch kind {
        case .createAlbum: "Create the “\(Thresholds.wallpaperAlbumName)” album?"
        case .changeAlbum: "Change the “\(Thresholds.wallpaperAlbumName)” album?"
        }
    }

    /// The sentence that names the change. Every count in it is a real number
    /// this particular act will produce — the whole point of asking before the
    /// change rather than reporting after it.
    var message: String {
        let safety = "Your photos themselves aren’t changed, moved, or deleted."
        switch kind {
        case .createAlbum:
            return "Alpenglow will create an album named “\(Thresholds.wallpaperAlbumName)” in Photos. \(safety)"
        case .changeAlbum:
            var clauses: [String] = []
            if added > 0 { clauses.append("add \(added) \(photos(added))") }
            if removed > 0 { clauses.append("remove \(removed) \(photos(removed))") }
            guard !clauses.isEmpty else {
                // A sync with nothing to add or remove still rebuilds the
                // album to impose the running order (FR-6.2). That is a change
                // to the album, so it is still asked about — and named for
                // what it actually is rather than as "add 0, remove 0".
                return "Alpenglow will reorder the \(total) \(photos(total)) in the “\(Thresholds.wallpaperAlbumName)” album. \(safety)"
            }
            return "Alpenglow will \(clauses.joined(separator: " and ")) in the “\(Thresholds.wallpaperAlbumName)” album, which will then hold \(total) \(photos(total)). \(safety)"
        }
    }

    /// What the button that goes ahead is called — named for the act, so the
    /// alert can be answered without re-reading the title.
    var confirmTitle: String {
        switch kind {
        case .createAlbum: "Create Album"
        case .changeAlbum: "Change Album"
        }
    }

    private func photos(_ count: Int) -> String { count == 1 ? "photo" : "photos" }
}

/// Whether the app still asks before each kind of change.
///
/// `UserDefaults`, and absent means "ask": a fresh install asks about
/// everything, which is the only safe default for a setting whose purpose is
/// consent. Nothing writes `true` back except the user turning asking on
/// again — a key that is present and true is indistinguishable from an absent
/// one, deliberately.
@MainActor
enum PhotosChangeConsent {
    static func shouldAsk(_ kind: PhotosChangeKind) -> Bool {
        UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool ?? true
    }

    static func setShouldAsk(_ kind: PhotosChangeKind, _ shouldAsk: Bool) {
        UserDefaults.standard.set(shouldAsk, forKey: kind.defaultsKey)
    }
}

/// A change waiting on the user's answer, and the way back to the work that
/// asked (FR-1.9).
///
/// The asking is a suspension in the middle of the sync, not a step before it:
/// `WallpaperAlbumSync` computes exactly what it is about to do, hands that
/// here, and waits. That is what lets the alert name real counts instead of a
/// forecast, and what makes "Cancel" mean the library was never touched —
/// there is nothing to undo, because nothing has happened yet.
@MainActor
struct PendingPhotosChange {
    let change: PhotosChange
    /// Resumes the waiting sync with the user's answer. Exactly one call ever
    /// reaches it — `ExportModel.answerPendingChange` clears the pending change
    /// before resuming.
    let resume: (Bool) -> Void
}
