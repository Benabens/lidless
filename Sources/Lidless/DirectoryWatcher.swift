import Foundation

/// Calls back on the main actor whenever an entry is added to, removed from or replaced in a
/// directory. `lidless-hook` writes session files atomically, so every update is a rename here.
@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    func start(watching directory: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
