import CoreGraphics
import Foundation
import Photos
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared PHImageManager request, used by every image-loading call site
/// (analysis bitmaps, grid thumbnails, duel cards). Cancels the underlying
/// PHImageManager request when the surrounding Task is cancelled, so fast
/// grid scrolling or rapid dueling doesn't pile up abandoned decode work.
nonisolated enum PhotoImageLoading {
    /// Thread-safe holder for the request ID: `onCancel` can run on any thread,
    /// possibly before `requestImage` has returned its ID.
    private final class RequestIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var id: PHImageRequestID?

        func set(_ id: PHImageRequestID) {
            lock.lock(); defer { lock.unlock() }
            self.id = id
        }

        func cancel(using manager: PHImageManager) {
            lock.lock(); defer { lock.unlock() }
            if let id { manager.cancelImageRequest(id) }
        }
    }

    // @concurrent: forces this onto the background concurrent executor even
    // when called from a @MainActor view's `.task` — otherwise the call runs
    // synchronously on the caller's actor up to its first suspension point,
    // which for a plain `nonisolated` async func means the main actor.
    @concurrent
    static func image(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowNetwork: Bool
    ) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowNetwork
        options.resizeMode = .fast

        let manager = PHImageManager.default()
        let requestBox = RequestIDBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let id = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, _ in
                    // The only place the app has to know which platform it is
                    // on to load a photo: PhotoKit hands back the platform's
                    // own image class (NSImage here, UIImage there) and offers
                    // no CGImage-returning request at a target size, so the
                    // unwrap differs even though everything downstream is
                    // CGImage.
                    #if os(macOS)
                    continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    #else
                    continuation.resume(returning: image?.cgImage)
                    #endif
                }
                requestBox.set(id)
            }
        } onCancel: {
            requestBox.cancel(using: manager)
        }
    }
}
