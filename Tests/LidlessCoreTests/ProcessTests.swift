import Foundation
import Testing
import LidlessCore

@Suite("Finding the agent process behind a hook")
struct ProcessTreeTests {
    /// pid → (parent pid, executable name)
    private func lookup(_ table: [Int32: (Int32, String)]) -> (Int32) -> ProcessSnapshot? {
        { pid in
            table[pid].map { ProcessSnapshot(pid: pid, parentPID: $0.0, name: $0.1, startTime: nil) }
        }
    }

    @Test func skipsTheShellTheAgentUsedToRunTheHook() {
        let tree = lookup([20: (10, "sh"), 10: (5, "node"), 5: (1, "Terminal")])
        #expect(ProcessTree.agentProcess(parentOfHook: 20, lookup: tree) == 10)
    }

    @Test func skipsNestedShells() {
        let tree = lookup([30: (20, "bash"), 20: (10, "zsh"), 10: (5, "codex"), 5: (1, "iTerm2")])
        #expect(ProcessTree.agentProcess(parentOfHook: 30, lookup: tree) == 10)
    }

    @Test func aDirectParentThatIsNotAShellIsTheAgent() {
        let tree = lookup([10: (5, "claude"), 5: (1, "zsh")])
        #expect(ProcessTree.agentProcess(parentOfHook: 10, lookup: tree) == 10)
    }

    @Test func fallsBackToTheDirectParentWhenTheTreeCannotBeRead() {
        #expect(ProcessTree.agentProcess(parentOfHook: 20, lookup: { _ in nil }) == 20)
    }

    @Test func neverClimbsUpToLaunchd() {
        let tree = lookup([20: (1, "sh"), 1: (0, "launchd")])
        #expect(ProcessTree.agentProcess(parentOfHook: 20, lookup: tree) == 20)
    }

    @Test func survivesACycleInTheLookup() {
        let tree = lookup([20: (30, "sh"), 30: (20, "bash")])
        let found = ProcessTree.agentProcess(parentOfHook: 20, lookup: tree)
        #expect([20, 30].contains(found))
    }
}

@Suite("Process probe")
struct ProcessProbeTests {
    @Test func describesTheCurrentProcess() throws {
        let snapshot = try #require(ProcessProbe.snapshot(of: getpid()))
        #expect(snapshot.pid == getpid())
        #expect(snapshot.parentPID == getppid())
        #expect(!snapshot.name.isEmpty)
        let start = try #require(snapshot.startTime)
        #expect(start < Date())
        #expect(start > Date().addingTimeInterval(-3600))
    }

    @Test func theCurrentProcessIsAlive() throws {
        let start = try #require(ProcessProbe.snapshot(of: getpid())?.startTime)
        #expect(ProcessProbe.isAlive(pid: getpid(), startedAt: start))
        #expect(ProcessProbe.isAlive(pid: getpid(), startedAt: nil))
    }

    @Test func aRecycledPIDIsNotMistakenForTheOriginalProcess() {
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(ProcessProbe.isAlive(pid: getpid(), startedAt: longAgo) == false)
    }

    @Test func aProcessThatExitedIsNotAlive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        #expect(ProcessProbe.isAlive(pid: pid, startedAt: nil) == false)
        #expect(ProcessProbe.snapshot(of: pid) == nil)
    }
}
