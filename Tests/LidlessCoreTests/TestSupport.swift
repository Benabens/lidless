import Foundation

/// A throwaway directory that removes itself when the test is done with it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidless-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ path: String) -> URL {
        url.appendingPathComponent(path)
    }

    @discardableResult
    func write(_ contents: String, to path: String, mode: Int? = nil) throws -> URL {
        let target = file(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        return target
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: file(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: file(path).path)
    }
}
