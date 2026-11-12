import Foundation
import Observation

/// A build of the picture's pixels: what it is of, and the work that makes them (finished or not).
struct PicturePixelsBuild {
    var identity: PicturePixelsIdentity
    var task: Task<PicturePixels?, Never>
}

/// The pixels of the open document's picture, for the tools that read it (color copy, the ruler, smart selection, the
/// magnifier, object removal, contrast): one `PicturePixels` per picture, built off the main actor.
///
/// **When they are built.** Not until a tool first asks (`loadPicturePixels()` or `currentPicturePixels()`): a large picture's
/// pixels take hundreds of megabytes, and most editing never needs them. From then on they are kept current: whenever the
/// picture changes (`AnnotationDocument.picturePixelsIdentity`: a crop, a turn, a flip, a resize, the canvas or its fill, a
/// redaction, which are exactly the changes the secrets check rescans on, plus the images placed on the picture), they are
/// rebuilt after a quiet `picturePixelsRebuildDelay`, at user-initiated priority, so a run of changes builds once. Drawing an
/// arrow or typing a label changes no pixel here and builds nothing.
///
/// **Reading them.** `picturePixels` is the pixels of the picture as it is now, or nil while they are being built: never
/// pixels of an earlier picture, whose coordinates would be off. Pixels of an older picture are let go as soon as a new build
/// starts. A tool that can wait (a click, a key) awaits `currentPicturePixels()` instead.
extension AnnotationEditor {
    /// How long the picture must stay unchanged before its pixels are rebuilt.
    static let picturePixelsRebuildDelay = Duration.milliseconds(250)

    /// The pixels of the picture as it is now, ready to read on the main actor; nil before the first `loadPicturePixels()`,
    /// while they are being built, or when the picture can't be read (no base image, a picture too large for a sampler).
    /// Observable: a view that reads it updates when they arrive.
    public var picturePixels: PicturePixels? {
        guard let pixels = builtPicturePixels, pixels.identity == document.picturePixelsIdentity else { return nil }
        return pixels
    }

    /// Asks for the picture's pixels: starts building them unless they are ready or being built, and from then on keeps them
    /// current as the picture changes. Returns at once; `picturePixels` has them when they are done. Call it when a pixel tool
    /// becomes active (or the pointer enters the canvas with one), so they are ready by the time it reads them.
    public func loadPicturePixels() {
        startWatchingPicturePixels()
        _ = buildPicturePixels()
    }

    /// The pixels of the picture as it is now, built first if they aren't ready, or nil when the picture can't be read. If the
    /// picture changes while this waits, the result is of the picture as it was when it was called (`identity` says which).
    /// Keeps them current afterwards, as `loadPicturePixels()` does.
    public func currentPicturePixels() async -> PicturePixels? {
        startWatchingPicturePixels()
        return await buildPicturePixels().value
    }

    // MARK: Building

    /// The build for the picture as it is now: the one under way or finished, or a new one. A new build drops the pixels of
    /// the older picture, so two large pictures are never held at once beyond the build itself.
    private func buildPicturePixels() -> Task<PicturePixels?, Never> {
        let identity = document.picturePixelsIdentity
        if let build = picturePixelsBuild, build.identity == identity { return build.task }
        picturePixelsRebuild?.cancel()
        picturePixelsRebuild = nil
        builtPicturePixels = nil
        let document = document, images = images
        let task = Task.detached(priority: .userInitiated) {
            PicturePixels.make(of: document, images: images)
        }
        picturePixelsBuild = PicturePixelsBuild(identity: identity, task: task)
        Task { [weak self] in
            let pixels = await task.value
            // Only the build still wanted is kept: a newer picture has started its own.
            guard let self, picturePixelsBuild?.identity == identity else { return }
            builtPicturePixels = pixels
        }
        return task
    }

    // MARK: Watching

    /// Watches the document for picture changes, once; the first ask turns it on, and it lasts as long as the editor.
    private func startWatchingPicturePixels() {
        guard picturePixelsBuild == nil else { return }
        watchPicturePixels()
    }

    /// Reads the document and registers for its next change. The change is reported before the new value is set, so it is
    /// read again on the next turn of the main actor, when it has landed; reading it there also registers the next watch.
    private func watchPicturePixels() {
        let identity = withObservationTracking {
            document.picturePixelsIdentity
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchPicturePixels() }
        }
        guard let build = picturePixelsBuild, build.identity != identity else {
            // The same picture (an arrow drawn, a label typed): a rebuild waiting for a picture that came back is let go.
            picturePixelsRebuild?.cancel()
            picturePixelsRebuild = nil
            return
        }
        picturePixelsRebuild?.cancel()
        picturePixelsRebuild = Task { [weak self] in
            do { try await Task.sleep(for: Self.picturePixelsRebuildDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            picturePixelsRebuild = nil
            _ = buildPicturePixels()
        }
    }
}
