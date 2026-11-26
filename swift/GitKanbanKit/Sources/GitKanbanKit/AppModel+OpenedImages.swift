import Foundation

extension AppModel {
    /// Files opened in Tasks: images dragged onto the Dock icon (a screenshot's floating
    /// thumbnail too) or sent with Open With (GITKITTIE-105). Every image among them starts
    /// one new task, as images dropped on the board do: on the board that is open, in its
    /// first open lane; with no board open, after asking which board. Before the app has
    /// restored — a drop that launched it — they wait for `restore()`.
    ///
    /// Returns how many of the files were images. None, and `errorMessage` says so.
    @discardableResult
    public func openFiles(_ urls: [URL]) async -> Int {
        // Read now: the sandbox lets the app read a file it was asked to open, and a large
        // HEIC is re-encoded, so it is read off the main thread.
        let images = await Task.detached(priority: .userInitiated) {
            urls.compactMap { TaskImage.from(fileURL: $0) }
        }.value
        guard !images.isEmpty else {
            errorMessage = urls.count == 1
                ? "Tasks makes a task from an image. \(urls[0].lastPathComponent) is not one."
                : "Tasks makes a task from images. None of these files is one."
            return 0
        }
        if isRestoring {
            imagesAwaitingRestore += images
        } else {
            requestNewTask(images: images)
        }
        return images.count
    }

    /// `restore()` is done and the last board is open again: start the task the images and
    /// the request opened during launch are for (one task, holding both).
    func startWhatWasOpenedBeforeRestore() {
        let images = imagesAwaitingRestore
        let request = requestAwaitingRestore
        imagesAwaitingRestore = []
        requestAwaitingRestore = nil
        guard !images.isEmpty || request != nil else { return }
        requestNewTask(images: images, request: request)
    }
}
