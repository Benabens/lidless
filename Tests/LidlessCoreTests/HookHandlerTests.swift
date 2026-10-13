import Foundation
import Testing
import LidlessCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func context(
    _ agent: Agent = .claude,
    key: String? = "abc-123",
    pid: Int32 = 500,
    cwd: String? = "/Users/me/project",
    at seconds: TimeInterval = 0
) -> HookContext {
    HookContext(agent: agent, sessionKey: key, pid: pid, processStart: at(-60), cwd: cwd, now: at(seconds))
}

@Suite("Hook events become session files")
struct HookHandlerTests {
    let directory: TemporaryDirectory
    let store: SessionStore
    let handler: HookHandler

    init() throws {
        directory = try TemporaryDirectory()
        store = SessionStore(directory: directory.file("sessions"))
        handler = HookHandler(store: store, heartbeatInterval: 15)
    }

    @Test func aPromptMarksTheSessionAsWorking() throws {
        try handler.handle(.prompt, context: context(at: 5))

        let sessions = store.loadAll()
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.agent == .claude)
        #expect(session.pid == 500)
        #expect(session.processStart == at(-60))
        #expect(session.cwd == "/Users/me/project")
        #expect(session.state == .working)
        #expect(session.workingSince == at(5))
        #expect(session.idleSince == nil)
        #expect(session.updatedAt == at(5))
    }

    @Test func stopMarksItIdleAndRemembersWhenTheTurnEnded() throws {
        try handler.handle(.prompt, context: context(at: 5))
        try handler.handle(.stop, context: context(at: 90))

        let session = try #require(store.loadAll().first)
        #expect(session.state == .idle)
        #expect(session.workingSince == nil)
        #expect(session.idleSince == at(90))
    }

    @Test func activityRevivesAnIdleSession() throws {
        try handler.handle(.prompt, context: context(at: 0))
        try handler.handle(.stop, context: context(at: 50))
        try handler.handle(.activity, context: context(at: 70))

        let session = try #require(store.loadAll().first)
        #expect(session.state == .working)
        #expect(session.workingSince == at(70))
        #expect(session.idleSince == nil)
    }

    @Test func activityDuringATurnOnlyRefreshesTheHeartbeat() throws {
        try handler.handle(.prompt, context: context(at: 0))
        try handler.handle(.activity, context: context(at: 40))

        let session = try #require(store.loadAll().first)
        #expect(session.workingSince == at(0))
        #expect(session.updatedAt == at(40))
    }

    @Test func burstsOfActivityDoNotRewriteTheFileEveryTime() throws {
        try handler.handle(.prompt, context: context(at: 0))
        try handler.handle(.activity, context: context(at: 14))
        #expect(store.loadAll().first?.updatedAt == at(0))

        try handler.handle(.activity, context: context(at: 15))
        #expect(store.loadAll().first?.updatedAt == at(15))
    }

    @Test func aNewPromptStartsANewTurnEvenIfTheLastOneNeverStopped() throws {
        try handler.handle(.prompt, context: context(at: 0))
        try handler.handle(.prompt, context: context(at: 300))

        #expect(store.loadAll().first?.workingSince == at(300))
    }

    @Test func aNewSessionStartsIdleAndGrantsNoGrace() throws {
        try handler.handle(.start, context: context(at: 0))

        let session = try #require(store.loadAll().first)
        #expect(session.state == .idle)
        #expect(session.idleSince == nil)
    }

    @Test func aSessionStartInTheMiddleOfATurnDoesNotInterruptIt() throws {
        // Agents fire their session-start event again after compacting the context.
        try handler.handle(.prompt, context: context(at: 0))
        try handler.handle(.start, context: context(at: 200))

        let session = try #require(store.loadAll().first)
        #expect(session.state == .working)
        #expect(session.workingSince == at(0))
    }

    @Test func aSessionResumedInANewProcessStartsOver() throws {
        try handler.handle(.prompt, context: context(pid: 500, at: 0))
        try handler.handle(.start, context: context(pid: 900, at: 400))

        let sessions = store.loadAll()
        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 900)
        #expect(sessions.first?.state == .idle)
    }

    @Test func stopForAnUnknownSessionStillRecordsTheEndOfATurn() throws {
        try handler.handle(.stop, context: context(at: 30))

        let session = try #require(store.loadAll().first)
        #expect(session.state == .idle)
        #expect(session.idleSince == at(30))
    }

    @Test func endForgetsTheSession() throws {
        try handler.handle(.prompt, context: context(at: 0))
        try handler.handle(.end, context: context(at: 10))

        #expect(store.loadAll().isEmpty)
    }

    @Test func sessionsAreKeptApartPerAgentAndPerSessionID() throws {
        try handler.handle(.prompt, context: context(.claude, key: "same", pid: 1))
        try handler.handle(.prompt, context: context(.codex, key: "same", pid: 2))
        try handler.handle(.prompt, context: context(.claude, key: "other", pid: 3))

        #expect(store.loadAll().count == 3)
    }

    @Test func withoutASessionIDTheProcessIdentifiesTheSession() throws {
        try handler.handle(.prompt, context: context(key: nil, pid: 77, at: 0))
        try handler.handle(.stop, context: context(key: nil, pid: 77, at: 20))

        let sessions = store.loadAll()
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .idle)
    }

    @Test func oneProcessCanHostSeveralSessions() throws {
        // A desktop app server runs many agent threads in a single process.
        try handler.handle(.prompt, context: context(key: "thread-a", pid: 500, at: 0))
        try handler.handle(.start, context: context(key: "thread-b", pid: 500, at: 60))

        let sessions = store.loadAll()
        #expect(sessions.count == 2)
        #expect(sessions.contains { $0.state == .working })
    }

    @Test func hostileSessionIDsCannotEscapeTheSessionsDirectory() throws {
        try handler.handle(.prompt, context: context(key: "../../../escape/attempt"))

        #expect(store.loadAll().count == 1)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(entries == ["sessions"])
    }
}

@Suite("Session store")
struct SessionStoreTests {
    @Test func anEmptyOrMissingDirectoryHasNoSessions() throws {
        let directory = try TemporaryDirectory()
        #expect(SessionStore(directory: directory.file("nowhere")).loadAll().isEmpty)
    }

    @Test func unreadableFilesAreSkippedInsteadOfFailingEverything() throws {
        let directory = try TemporaryDirectory()
        let store = SessionStore(directory: directory.file("sessions"))
        try HookHandler(store: store).handle(.prompt, context: context())
        try directory.write("{ not json", to: "sessions/garbage.json")
        try directory.write("hello", to: "sessions/notes.txt")

        #expect(store.loadAll().count == 1)
    }

    @Test func removingASessionDeletesItsFile() throws {
        let directory = try TemporaryDirectory()
        let store = SessionStore(directory: directory.file("sessions"))
        try HookHandler(store: store).handle(.prompt, context: context())
        let id = try #require(store.loadAll().first?.id)

        store.remove(id: id)
        #expect(store.loadAll().isEmpty)
    }
}

@Suite("Hook payload")
struct HookPayloadTests {
    @Test func readsTheSessionIDAndWorkingDirectory() {
        let json = #"{"session_id":"8f2c","transcript_path":"/x.jsonl","cwd":"/Users/me/app","hook_event_name":"Stop"}"#
        let payload = HookPayload.parse(Data(json.utf8))
        #expect(payload == HookPayload(sessionID: "8f2c", cwd: "/Users/me/app"))
    }

    @Test func toleratesMissingEmptyOrMalformedInput() {
        #expect(HookPayload.parse(Data()) == HookPayload(sessionID: nil, cwd: nil))
        #expect(HookPayload.parse(Data("not json".utf8)) == HookPayload(sessionID: nil, cwd: nil))
        #expect(HookPayload.parse(Data(#"{"session_id":42,"cwd":""}"#.utf8)) == HookPayload(sessionID: nil, cwd: nil))
        #expect(HookPayload.parse(Data("[1,2]".utf8)) == HookPayload(sessionID: nil, cwd: nil))
    }

    @Test func stillFindsTheSessionIDInAPayloadCutShort() {
        // Tool results can make a payload huge; the hook stops reading at some point.
        let truncated = #"{"session_id":"8f2c","cwd":"/Users/me/app","tool_response":{"stdout":"lorem ips"#
        let payload = HookPayload.parse(Data(truncated.utf8))
        #expect(payload == HookPayload(sessionID: "8f2c", cwd: "/Users/me/app"))
    }

    @Test func unescapesPathsWhenReadingACutShortPayload() {
        let truncated = #"{"session_id" : "id-1", "cwd": "/Users/me/my \"quoted\" dir\/x", "prompt": "unfinis"#
        let payload = HookPayload.parse(Data(truncated.utf8))
        #expect(payload.sessionID == "id-1")
        #expect(payload.cwd == #"/Users/me/my "quoted" dir/x"#)
    }
}

@Suite("Where Lidless keeps its files")
struct LidlessPathsTests {
    @Test func livesInApplicationSupportByDefault() {
        let paths = LidlessPaths(home: URL(fileURLWithPath: "/Users/me"), environment: [:])
        #expect(paths.supportDirectory.path == "/Users/me/Library/Application Support/Lidless")
        #expect(paths.sessionsDirectory.path == "/Users/me/Library/Application Support/Lidless/sessions")
        #expect(paths.installedHook.path == "/Users/me/Library/Application Support/Lidless/bin/lidless-hook")
    }

    @Test func canBeRedirectedForTestsAndSandboxes() {
        let paths = LidlessPaths(
            home: URL(fileURLWithPath: "/Users/me"), environment: ["LIDLESS_SUPPORT_DIR": "/tmp/elsewhere"]
        )
        #expect(paths.sessionsDirectory.path == "/tmp/elsewhere/sessions")
    }
}
