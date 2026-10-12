import Foundation

/// The directory of session files shared by `lidless-hook` (writer) and the app (reader).
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Every readable session. Files that cannot be decoded are skipped.
    public func loadAll() -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(read)
            .sorted { $0.id < $1.id }
    }

    public func load(id: String) -> SessionRecord? {
        read(fileURL(for: id))
    }

    public func save(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func read(_ url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(SessionRecord.sanitized(id) + ".json")
    }
}

extension SessionRecord {
    /// A stable identifier that is also a safe file name, whatever the agent sent as session ID.
    public static func identifier(agent: Agent, sessionKey: String?, pid: Int32) -> String {
        let key = sessionKey.flatMap { $0.isEmpty ? nil : $0 } ?? "pid-\(pid)"
        return sanitized("\(agent.rawValue)-\(key)")
    }

    static func sanitized(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(raw.prefix(96).map { allowed.contains($0) ? $0 : "_" })
    }
}
