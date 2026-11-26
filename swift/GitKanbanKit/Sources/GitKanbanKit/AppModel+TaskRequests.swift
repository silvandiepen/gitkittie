import Foundation

extension AppModel {
    /// A `gitkittie-tasks://new` URL opened in Tasks (GitKittie Mail's Make Task, GKM-033):
    /// starts a new task with its title and description the way ⌘N does — on the board that
    /// is open, in its first open lane; with none open, after asking which board. Nothing is
    /// saved until the person presses Create. Before the app has restored (the URL launched
    /// it) the request waits for `restore()`.
    ///
    /// False, with `errorMessage` set, for a URL that is not such a request.
    @discardableResult
    public func openTaskRequest(_ url: URL) -> Bool {
        guard let request = NewTaskRequest(url: url) else {
            errorMessage = "Tasks can't make a task from that link."
            return false
        }
        if isRestoring {
            requestAwaitingRestore = request
        } else {
            requestNewTask(images: [], request: request)
        }
        return true
    }

    /// The request the new-task sheet starts with (or that arrived while it is up), handed
    /// over once.
    public func takeNewTaskRequest() -> NewTaskRequest? {
        defer { newTaskRequest = nil }
        return newTaskRequest
    }
}
