import Photos
import Observation
import os

/// Observable wrapper around the app's Photos authorization status.
///
/// The app is read-only: it never writes to the library. PhotoKit, however,
/// only exposes a read/write access level, so we request `.readWrite`; the
/// read-only guarantee is enforced by simply never calling any write APIs.
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
}
