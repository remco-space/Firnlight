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
    /// grant made in System Settings is picked up without a relaunch.
    func refresh() {
        let previous = status
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != previous {
            log.info("Authorization changed: \(String(describing: previous), privacy: .public) → \(String(describing: self.status), privacy: .public)")
        }
    }

    /// Whether the app can read assets (full or limited selection).
    var isAuthorized: Bool {
        status == .authorized || status == .limited
    }

    /// The platform's own privacy settings for this app (FR-1.2, FR-1.8).
    ///
    /// macOS has a system-wide Photos privacy pane listing every app; iOS puts
    /// each app's permissions on its own Settings page, which
    /// `openSettingsURLString` addresses. Shared rather than duplicated
    /// because two tabs need it: the Library tab's access states, and the
    /// Export tab's limited-access notice.
    ///
    /// On iPhone and iPad this is also the *only* way to move from limited to
    /// full access (FR-1.8). There is no API for it: `requestAuthorization`
    /// never re-prompts once the status is determined, and
    /// `presentLimitedLibraryPicker` only edits which photos are selected.
    nonisolated static var settingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}
