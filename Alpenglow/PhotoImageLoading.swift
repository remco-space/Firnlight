import AppKit
import Photos

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
                    continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                }
                requestBox.set(id)
            }
        } onCancel: {
            requestBox.cancel(using: manager)
        }
    }
}
