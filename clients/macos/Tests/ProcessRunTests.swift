import Foundation
import Testing
@testable import VoiceSay

@Suite("ProcessRun")
struct ProcessRunTests {
    /// Output well past the ~64 KB pipe buffer must not deadlock (the pipe is
    /// drained before waitUntilExit) and must arrive whole, stderr included.
    @Test func largeOutputDoesNotDeadlock() {
        let r = ProcessRun.run(URL(fileURLWithPath: "/bin/sh"),
                               ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo E >&2"])
        guard case .ok(let out) = r else { Issue.record("expected .ok, got \(r)"); return }
        #expect(out.count == 300_002)
        #expect(out.hasSuffix("E\n"))
    }

    @Test func nonZeroExitCarriesDetail() {
        let r = ProcessRun.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom >&2; exit 3"])
        guard case .fail(let m) = r else { Issue.record("expected .fail"); return }
        #expect(m == "exit 3: boom")
    }

    @Test func detailFallsBackToEndState() {
        #expect(ProcessRun.ok("  \n").detail(stillUp: true) == "still up")
        #expect(ProcessRun.ok(" busy \n").detail(stillUp: false) == "busy")
        #expect(ProcessRun.fail("exit 5: x").detail(stillUp: false) == "exit 5: x")
    }

    @Test func pollStateStopsOnTargetOrDeadline() async {
        let hit = await ProcessRun.pollState(until: true, within: 5, everyNs: 1_000_000) { true }
        #expect(hit)
        let start = Date()
        let miss = await ProcessRun.pollState(until: true, within: 0.05, everyNs: 10_000_000) { false }
        #expect(!miss)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
