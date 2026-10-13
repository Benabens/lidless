import Darwin
import Foundation
import LidlessCore

// lidless-hook <agent> <event> [--pid <pid>]
//
// Called by the hooks of Claude Code, Codex and Gemini CLI. Records the event as a session file
// for the Lidless app to pick up. A hook must never get in the agent's way, so this prints nothing
// on stdout (agents read it), never blocks on stdin, and always exits 0.

let usage = "usage: lidless-hook <claude|codex|gemini> <start|prompt|activity|stop|end> [--pid <pid>]\n"

/// Reads the agent's JSON payload. Gives up after a second of silence in case stdin is left open.
func readStandardInput(limit: Int = 32 << 20) -> Data {
    guard isatty(STDIN_FILENO) == 0 else { return Data() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while data.count < limit {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 1000) > 0 else { break }
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print(Lidless.version)
    exit(0)
}

var explicitPID: Int32?
if let flag = arguments.firstIndex(of: "--pid"), flag + 1 < arguments.count {
    explicitPID = Int32(arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}

guard arguments.count == 2,
      let agent = Agent(rawValue: arguments[0]),
      let event = HookEvent(rawValue: arguments[1])
else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(0)
}

let payload = HookPayload.parse(readStandardInput())
let environment = ProcessInfo.processInfo.environment
let pid = explicitPID ?? ProcessTree.agentProcess(parentOfHook: getppid(), lookup: ProcessProbe.snapshot)
let sessionKey = payload.sessionID ?? (agent == .gemini ? environment["GEMINI_SESSION_ID"] : nil)

let context = HookContext(
    agent: agent,
    sessionKey: sessionKey,
    pid: pid,
    processStart: ProcessProbe.snapshot(of: pid)?.startTime,
    cwd: payload.cwd ?? FileManager.default.currentDirectoryPath,
    now: Date()
)
let store = SessionStore(directory: LidlessPaths(environment: environment).sessionsDirectory)
_ = try? HookHandler(store: store).handle(event, context: context)
exit(0)
