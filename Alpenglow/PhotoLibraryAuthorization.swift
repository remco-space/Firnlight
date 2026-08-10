import Photos
import Observation
import os
#if !os(macOS)
import UIKit
#endif

/// Observable wrapper around the app's Photos authorization status.
///
/// `.readWrite` is the level the app actually needs, not an over-ask forced by
/// a coarse API: FR-1.4 sanctions exactly one kind of write, and
/// `WallpaperAlbumSync` performs it — creating the wallpaper album and setting
/// its membership. The user's photos themselves are never edited or deleted,
/// which is a discipline of the code (that one file is the only write path)
/// rather than something PhotoKit can enforce, since it offers no
/// album-membership-only access level to ask for.
@MainActor
@Observable
final class PhotoLibraryAuthorization {
    private(set) var status: PHAuthorizationStatus

    private let log = Logger(subsystem: "space.remco.Alpenglow", category: "Authorization")

    init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log.info("Initial authorization status: \(String(describing: self.status), privacy: .public)")
    }

    /// Prompts the user for access and updates ``status`` with the result.
    func request() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        log.info("Authorization request result: \(String(describing: self.status), privacy: .public)")
    }

    /// Re-reads the current status — call when the app becomes active so a
    /// grant made in System Settings is picked up without a relaunch (FR-1.3),
    /// and whenever the library reports a change, which is how a *narrowing*
    /// to a selection is noticed while the app is open (FR-1.8).
    func refresh() {
        let previous = status
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != previous {
            log.info("Authorization changed: \(String(describing: previous), privacy: .public) → \(String(describing: self.status), privacy: .public)")
        }
    }

    /// Whether the app may work at all — FR-1.8's floor.
    ///
    /// `.authorized` alone: a limited selection deliberately does **not**
    /// count. Two things follow from the whole library being the unit the app
    /// works on. It cannot tell a deleted photo from an unselected one (a
    /// fetch under `.limited` returns only the selection, so every photo
    /// outside it looks deleted), which is exactly what FR-2.6 asks it to
    /// notice; and PhotoKit will not let it create or fetch a user album under
    /// `.limited` at all, failing *silently* — `performChanges` reports success
    /// and the following fetch returns nothing — so the album FR-6.1 exists to
    /// maintain could never be written while the app looked like it was
    /// working. Treating a selection as "not granted" is what keeps the app
    /// from appearing to work on part of a library.
    var isAuthorized: Bool {
        status == .authorized
    }

    /// The platform's own privacy settings for this app (FR-1.2, FR-1.8).
    ///
    /// macOS has a system-wide Photos privacy pane listing every app; iOS puts
    /// each app's permissions on its own Settings page, which
    /// `openSettingsURLString` addresses.
    ///
    /// This is also the *only* way to move from limited to full access
    /// (FR-1.8). There is no API for it: `requestAuthorization` never
    /// re-prompts once the status is determined, and PhotoKit's limited-library
    /// picker only edits which photos are selected (and is
    /// `API_UNAVAILABLE(macos)` besides).
    nonisolated static var settingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

/// Tells the app that the user's library changed, so it can keep up with it
/// on its own (FR-2.6, FR-2.7).
///
/// The whole of "there is no re-scan control, because there is nothing a
/// re-scan would find that the app has not already found" rests on this: Photos
/// reports every insertion, deletion and edit as it happens, so the app is told
/// rather than having to be asked to look.
///
/// `nonisolated` and `Sendable` because `photoLibraryDidChange` is delivered on
/// an arbitrary queue — PhotoKit documents no isolation for it — so the
/// callback hops to wherever it needs to be rather than this type pretending to
/// an isolation it does not have. Registration happens in `init` and
/// unregistration in `deinit`, so the observer's lifetime is exactly the
/// object's and no call site can leave one registered against a deallocated
/// owner.
///
/// It carries no diff. `PHChange` can only be applied to a fetch result the
/// caller already holds, and the app's unit of catching up is a metadata pass
/// over the whole library reconciled against the store (`LibraryScanner`),
/// which needs no diff to be correct and is cheap enough to repeat. What the
/// change tells the app is *that* something moved, which is the part it cannot
/// work out for itself.
nonisolated final class PhotoLibraryWatcher: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
