import Foundation

/// Agents call a copy of `lidless-hook` kept outside the app bundle, so moving or rebuilding the
/// app never leaves their hooks pointing at nothing. This keeps that copy current.
enum HookProvisioner {
    static func provision(to destination: URL) {
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("lidless-hook"),
            FileManager.default.isExecutableFile(atPath: bundled.path),
            !FileManager.default.contentsEqual(atPath: bundled.path, andPath: destination.path)
        else { return }

        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".lidless-hook-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: staging)
            // An agent may be running the old copy right now; rename swaps it atomically.
            guard rename(staging.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
        }
    }
}
