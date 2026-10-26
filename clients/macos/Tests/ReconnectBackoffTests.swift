// SSE reconnect backoff: doubles across failed attempts, caps at 30 s, and
// starts over after an attempt that had connected (a daemon restart after
// hours of uptime must not wait out a delay built up long before).

import Testing
@testable import VoiceSay

@Suite("ReconnectBackoff")
struct ReconnectBackoffTests {

    @Test("failed attempts that never connected double up to the cap")
    func doublesToCap() {
        var b = ReconnectBackoff()
        let delays = (0..<7).map { _ in b.nextDelay(afterConnected: false) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test("a drop after a working connection starts over at 1 s")
    func connectedDropResets() {
        var b = ReconnectBackoff()
        for _ in 0..<6 { _ = b.nextDelay(afterConnected: false) }   // at the cap
        #expect(b.nextDelay(afterConnected: true) == 1)
        #expect(b.nextDelay(afterConnected: false) == 2)
    }

    @Test("a clean stream end resets")
    func resetAfterCleanEnd() {
        var b = ReconnectBackoff()
        for _ in 0..<4 { _ = b.nextDelay(afterConnected: false) }
        b.reset()
        #expect(b.nextDelay(afterConnected: false) == 1)
    }
}
