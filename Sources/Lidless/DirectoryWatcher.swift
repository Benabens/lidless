import Foundation

/// Calls back on the main actor whenever an entry is added to, removed from or replaced in a
/// directory. `lidless-hook` writes session files atomically, so every update is a rename here.
///
/// Nothing else tells the app that an agent started working, so the watcher repairs itself: if
/// the directory is deleted or moved it starts over on a fresh one, and `ensureWatching()` retries
/// a watch that could not be set up.
@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var directory: URL?
    private var onChange: (@MainActor () -> Void)?

    func start(watching directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onChange = onChange
        watch()
    }

    /// Cheap to call on every pass.
    func ensureWatching() {
        if source == nil { watch() }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func watch() {
        stop()
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.source else { return }
                // The directory itself went away: the descriptor now watches nothing useful.
                if !current.data.isDisjoint(with: [.delete, .rename]) { self.watch() }
                self.onChange?()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }
}
