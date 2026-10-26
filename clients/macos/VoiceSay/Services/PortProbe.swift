import Foundation

/// Shared liveness probe for a localhost service. THE single ephemeral-session
/// probe recipe: `waitsForConnectivity = false` so a down port fails fast
/// within the caller's budget, and a fresh session per probe so a stale pooled
/// connection to a recently-downed server can't bleed a false "up".
///
/// Two flavors:
///   `answers(port:)` — "up" = ANY HTTP response at root (TTS backends return
///     200/404 either way; only a transport failure means down). Used by
///     `BackendController` (start/stop poll, 1.5 s) and `HealthMonitor`
///     (catalog refresh, 2.0 s).
///   `httpOK(url:)` — strict 200 on an absolute URL. Used by
///     `DaemonController` to confirm a start/stop end state via /health.
enum PortProbe {
    static func answers(port: Int, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        return await response(for: url, timeout: timeout) != nil
    }

    static func httpOK(url: URL, timeout: TimeInterval) async -> Bool {
        await response(for: url, timeout: timeout)?.statusCode == 200
    }

    private static func response(for url: URL, timeout: TimeInterval) async -> HTTPURLResponse? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            let (_, resp) = try await session.data(for: req)
            return resp as? HTTPURLResponse
        } catch { return nil }
    }
}
