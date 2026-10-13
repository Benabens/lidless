import Foundation
import Testing
import LidlessCore

/// Runs the real `lidless-hook` binary, the way an agent does.
@Suite("lidless-hook, the executable agents run")
struct HookExecutableTests {
    /// SwiftPM puts executables next to the test bundle.
    private static let hook: URL = {
        let products = Bundle.allBundles
            .first { $0.bundlePath.hasSuffix(".xctest") }?
            .bundleURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath).appendingPathComponent("../../../.build/debug").standardizedFileURL
        return products.appendingPathComponent("lidless-hook")
    }()

    private let support: TemporaryDirectory

    init() throws {
        support = try TemporaryDirectory()
    }

    private struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func run(_ arguments: [String], stdin: Data) throws -> Run {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = Self.hook
        process.arguments = arguments
        process.environment = ["LIDLESS_SUPPORT_DIR": support.url.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // The hook may exit without reading a large payload to the end; that must not fail the test.
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    private func payload(event: String) -> Data {
        Data(#"{"session_id":"silence-1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/app","hook_event_name":"\#(event)","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
    }

    private var sessionFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: support.file("sessions").path)) ?? []
    }

    // Whatever a hook prints can end up in the agent's context, and so in every later request.
    @Test(arguments: Agent.allCases)
    func printsNothingAndSucceedsForEveryEvent(agent: Agent) throws {
        for event in HookEvent.allCases {
            let result = try run([agent.rawValue, event.rawValue, "--pid", "\(getpid())"], stdin: payload(event: event.rawValue))
            #expect(result.status == 0, "\(agent.rawValue) \(event.rawValue)")
            #expect(result.stdout == "", "\(agent.rawValue) \(event.rawValue) wrote to stdout")
            #expect(result.stderr == "", "\(agent.rawValue) \(event.rawValue) wrote to stderr")
        }
    }

    @Test(arguments: [[], ["claude"], ["bogus", "prompt"], ["claude", "explode"], ["claude", "prompt", "extra"], ["--pid"]])
    func staysSilentEvenWhenAnAgentCallsItWrongly(arguments: [String]) throws {
        let result = try run(arguments, stdin: payload(event: "Stop"))
        #expect(result.status == 0)
        #expect(result.stdout == "")
        #expect(result.stderr == "")
        #expect(sessionFiles.isEmpty)
    }

    @Test(arguments: ["", "not json at all", "{\"session_id\":", "[1,2,3]", "\u{0}\u{1}\u{2}"])
    func staysSilentOnInputItCannotRead(input: String) throws {
        let result = try run(["codex", "prompt", "--pid", "\(getpid())"], stdin: Data(input.utf8))
        #expect(result.status == 0)
        #expect(result.stdout == "")
        #expect(result.stderr == "")
    }

    @Test func staysSilentOnAMultiMegabyteToolResult() throws {
        var big = Data(#"{"session_id":"big-1","cwd":"/Users/me/app","tool_response":{"stdout":""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "x"), count: 4 << 20))
        big.append(Data("\"}}".utf8))

        let result = try run(["claude", "activity", "--pid", "\(getpid())"], stdin: big)
        #expect(result.status == 0)
        #expect(result.stdout == "")
        #expect(result.stderr == "")
        #expect(sessionFiles == ["claude-big-1.json"])
    }

    @Test func recordsASessionFromStartToEnd() throws {
        let pid = "\(getpid())"
        _ = try run(["gemini", "prompt", "--pid", pid], stdin: payload(event: "BeforeAgent"))
        let store = SessionStore(directory: support.file("sessions"))
        let session = try #require(store.loadAll().first)
        #expect(session.agent == .gemini)
        #expect(session.state == .working)
        #expect(session.cwd == "/Users/me/app")
        #expect(session.pid == getpid())

        _ = try run(["gemini", "end", "--pid", pid], stdin: payload(event: "SessionEnd"))
        #expect(store.loadAll().isEmpty)
    }

    @Test func findsTheAgentProcessByItself() throws {
        // Without --pid the hook climbs from its parent: here, this test process.
        _ = try run(["claude", "prompt"], stdin: payload(event: "UserPromptSubmit"))
        let session = try #require(SessionStore(directory: support.file("sessions")).loadAll().first)
        #expect(session.pid == getpid())
        #expect(ProcessProbe.isAlive(pid: session.pid, startedAt: session.processStart))
    }
}
