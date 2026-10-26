// DaemonClient — single HTTP client for the voice-say daemon. It owns the
// base URL, a shared URLSession (real connection pooling) and one place for
// timeout policy, so no other type builds daemon requests.
//
// Why `final class` (not `actor`): every endpoint is a stateless HTTP
// call against an immutable session + decoder. An actor would serialize
// parallel daemon calls onto one executor for nothing and force `await`
// on `eventsURL` reads. URLSession is already thread-safe.

import Foundation

/// The one daemon-wire JSON codec (default strategies; models opt in to key
/// mapping per type). Both types are Sendable and safe for concurrent use.
enum Wire {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
}

final class DaemonClient: @unchecked Sendable {
    static let shared = DaemonClient()
    /// This app run's id on render requests (see RenderRequest.clientRef).
    nonisolated static let clientRef = "app-" + UUID().uuidString

    /// Override via the UserDefaults key `voicesay.daemonURL`, for a daemon
    /// on another port. Same host only: the app reads audio from the paths
    /// the daemon reports.
    let baseURL: URL

    private let session: URLSession

    init() {
        if let override = UserDefaults.standard.string(forKey: DefaultsKeys.baseURLOverride),
           let url = URL(string: override) {
            baseURL = url
        } else {
            baseURL = URL(string: "http://127.0.0.1:8890")!
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 5
        // Cap on a whole request. A render POST stays open until the episode
        // is done (a 40k-char script takes ~25 min), so this must outlast the
        // longest render; each request's own idle timeout still applies.
        cfg.timeoutIntervalForResource = Self.longestRenderS
        cfg.waitsForConnectivity = false
        // The bundle's version; a bare `swift test`/`swift run` has none.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        cfg.httpAdditionalHeaders = ["User-Agent": "VoiceSay/\(version) (macOS)"]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public endpoints

    func health() async throws -> HealthResponse { try await get("/health") }
    func config() async throws -> ConfigResponse { try await get("/config") }
    /// Lifetime render totals + current library size. 404 on a daemon that
    /// predates the route — callers treat any failure as "no stats".
    func stats() async throws -> StatsResponse { try await get("/stats") }

    /// Persist the default backend/voice on the daemon (writes
    /// config.local.toml + live-reloads). Pass nil to leave a field
    /// unchanged; pass "" for voice to clear it (backend picks). Returns
    /// the fresh config so callers can refresh from the authoritative state.
    func setConfig(defaultBackend: String? = nil,
                   defaultVoice: String? = nil,
                   sayThresholdChars: Int? = nil) async throws -> ConfigResponse {
        try await post("/config",
                       body: ConfigUpdateRequest(defaultBackend: defaultBackend,
                                                 defaultVoice: defaultVoice,
                                                 sayThresholdChars: sayThresholdChars),
                       timeout: 5)
    }

    func history(limit: Int = 500) async throws -> HistoryResponse {
        try await get("/history", query: ["limit": String(limit)], timeout: 3)
    }

    /// Longform render (chunk → one row). Always stream mode: it makes the
    /// daemon broadcast episode_start/chunk_ready/episode_complete on /events
    /// so the app can play-while-rendering and offer cancel / save-and-stop.
    /// On cancel the daemon returns 200 {cancelled:true, episode_id} with no
    /// archive.
    /// Upper bound for one render request (and the session's resource cap).
    nonisolated static let longestRenderS: TimeInterval = 4 * 3600

    /// How long a fresh render may run once its episode has started: about
    /// 1 s per 10 chars, at least 600 s (`voice-say render`'s rule). RenderQueue's
    /// watchdog enforces it from this app's episode_start, not from the POST:
    /// the POST may first wait at the daemon's gate behind another client's
    /// render, so the request itself only gets `longestRenderS`.
    nonisolated static func renderTimeout(chars: Int) -> TimeInterval {
        min(longestRenderS, max(600, TimeInterval(chars) / 10))
    }

    func renderLongform(text: String, backend: String, voice: String, speed: Double,
                        tags: [String], overlay: RenderOverlay = .none) async throws -> RenderResponse {
        try await post("/render_longform",
                       body: RenderRequest(text: text, backend: backend, voice: voice,
                                           speed: speed, tags: tags, title: overlay.title,
                                           series: overlay.series, episode: overlay.episode),
                       timeout: Self.longestRenderS)
    }

    func postProgress(ts: String, playedS: Double, durationS: Double? = nil,
                      completed: Bool? = nil, started: Bool = false) async throws -> ProgressInfo {
        try await post("/progress/\(ts)",
                       body: ProgressRequest(playedS: playedS, durationS: durationS,
                                             completed: completed, started: started),
                       timeout: 3)
    }

    func postOverlay(ts: String,
                     starred: Bool? = nil,
                     deleted: Bool? = nil,
                     tags: [String]? = nil,
                     removedTags: [String]? = nil,
                     bookmarks: [Bookmark]? = nil,
                     title: String? = nil) async throws -> Overlay {
        try await postOverlay(ts: ts, request: OverlayRequest(starred: starred, deleted: deleted,
                                                              tags: tags, removedTags: removedTags,
                                                              bookmarks: bookmarks, title: title))
    }

    func postOverlay(ts: String, request: OverlayRequest) async throws -> Overlay {
        try await post("/overlays/\(ts)", body: request, timeout: 3)
    }

    /// Announce that this app instance is taking playback for `ts`.
    /// Fire-and-forget by design — failure means another surface won't
    /// pause, which is mildly bad but never fatal.
    func announcePlaybackActive(ts: String) async {
        _ = try? await postVoid("/playback/active",
                                body: PlaybackActiveRequest(source: "voicesay", ts: ts),
                                timeout: 2)
    }

    /// Cancel a streaming render in progress (POST /episode/{id}/cancel) —
    /// discards it, no canonical row. 404 if it's no longer rendering.
    @discardableResult
    func cancelEpisode(id: String) async throws -> EpisodeControlResponse {
        try await post("/episode/\(id)/cancel", body: EmptyBody(), timeout: 5)
    }

    /// Save-and-stop a streaming render (POST /episode/{id}/finalize): keep the
    /// rendered-so-far audio as one row tagged "draft". 404 if not rendering.
    @discardableResult
    func finalizeEpisode(id: String) async throws -> EpisodeControlResponse {
        try await post("/episode/\(id)/finalize", body: EmptyBody(), timeout: 5)
    }

    /// Force save-and-stop (POST /episode/{id}/force_finalize): keep the
    /// already-completed chunks as a "draft" row but DROP the in-flight chunk
    /// instead of waiting for it to finish. 404 if not rendering.
    @discardableResult
    func forceFinalizeEpisode(id: String) async throws -> EpisodeControlResponse {
        try await post("/episode/\(id)/force_finalize", body: EmptyBody(), timeout: 5)
    }

    /// Continue a finalized-early draft (POST /episode/resume): the daemon
    /// re-chunks the draft's stored text, renders the remainder, and merges
    /// [draft + remainder] into ONE new row, superseding the draft. Like a
    /// fresh stream render, the streaming SSE (episode_start/chunk_ready/
    /// episode_complete) drives the UI; this POST stays open until completion,
    /// hence the long timeout. Returns the canonical entry shape.
    @discardableResult
    func resumeEpisode(fromTS ts: String) async throws -> RenderResponse {
        // The remaining length lives server-side: allow the longest render.
        try await post("/episode/resume", body: ResumeRequest(fromTS: ts), timeout: Self.longestRenderS)
    }

    /// Endpoint URL for the SSE event stream — EventStreamReader consumes
    /// it directly because it needs custom header handling.
    var eventsURL: URL { baseURL.appending(path: "/events") }

    /// "host:port" for display (Settings services row) — derived from the
    /// live baseURL so a `voicesay.daemonURL` override shows truthfully
    /// instead of a hardcoded loopback literal.
    var baseHostPort: String {
        "\(baseURL.host() ?? "127.0.0.1"):\(baseURL.port ?? 8890)"
    }

    // MARK: - Internal request plumbing

    private func get<T: Decodable>(_ path: String,
                                   query: [String: String] = [:],
                                   timeout: TimeInterval = 3) async throws -> T {
        // Unreachable-in-practice for our fixed localhost paths, but a bad
        // `voicesay.daemonURL` override shouldn't be able to crash the app —
        // fail as a normal request error instead.
        guard var comp = URLComponents(url: baseURL.appending(path: path),
                                       resolvingAgainstBaseURL: false) else {
            throw DaemonError.pipelineFailed(stage: "url", message: "bad base URL \(baseURL)")
        }
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comp.url else {
            throw DaemonError.pipelineFailed(stage: "url", message: "bad request URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return try Wire.decoder.decode(T.self, from: try await send(req))
    }

    private func post<B: Encodable, R: Decodable>(_ path: String,
                                                  body: B,
                                                  timeout: TimeInterval) async throws -> R {
        let req = try makePostRequest(path: path, body: body, timeout: timeout)
        return try Wire.decoder.decode(R.self, from: try await send(req))
    }

    private func postVoid<B: Encodable>(_ path: String,
                                        body: B,
                                        timeout: TimeInterval) async throws {
        let req = try makePostRequest(path: path, body: body, timeout: timeout)
        _ = try await send(req)
    }

    private func makePostRequest<B: Encodable>(path: String, body: B, timeout: TimeInterval) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try Wire.encoder.encode(body)
        return req
    }

    /// Run a request; map transport failure to `.unreachable` and
    /// non-200 to `.pipelineFailed` (if the body is JSON `{error, message}`)
    /// or `.http`. The caller decodes the success body.
    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DaemonError.unreachable(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw DaemonError.unreachable("no HTTP response")
        }
        if http.statusCode == 200 { return data }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stage = obj["error"] as? String {
            let msg = (obj["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw DaemonError.pipelineFailed(stage: stage, message: msg)
        }
        throw DaemonError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Errors

enum DaemonError: LocalizedError {
    case unreachable(String)
    case pipelineFailed(stage: String, message: String)
    case http(status: Int, body: String)
    case cancelled(episodeID: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "voice-say daemon unreachable: \(m)"
        case .pipelineFailed(let stage, let m): return "\(stage): \(m)"
        case .http(let s, _): return "HTTP \(s)"
        case .cancelled: return nil   // user-initiated; not an error to surface
        }
    }
}

// MARK: - Request bodies (Encodable)

struct RenderRequest: Encodable {  // internal: wire contract under test (Tests/WireContractTests)
    let text: String
    let backend: String
    let voice: String
    let speed: Double
    let tags: [String]
    /// Set on the new row's overlay by the daemon; nil → key absent.
    var title: String? = nil
    var series: String? = nil
    var episode: Int? = nil
    /// Pinned to "stream" (also the daemon's default): the app's whole
    /// streaming UI (episode_* SSE, cancel, save-and-stop) hangs off it.
    let mode = "stream"
    /// Echoed on episode_start, so this app tells its own episodes from ones
    /// an agent or the CLI started (those never touch playback).
    let clientRef = DaemonClient.clientRef
    enum CodingKeys: String, CodingKey {
        case text, backend, voice, speed, tags, title, series, episode, mode
        case clientRef = "client_ref"
    }
}

struct ProgressRequest: Encodable {  // internal: wire contract under test
    let playedS: Double
    let durationS: Double?
    // Optional so a position heartbeat can OMIT it: the daemon then preserves
    // the prior `completed` latch (progress.py) instead of resetting it. Only an
    // explicit ≥90%/end event sends `true`; nothing sends `false`. Swift's
    // synthesized Encodable drops nil optionals, so nil → key absent.
    let completed: Bool?
    let started: Bool

    enum CodingKeys: String, CodingKey {
        case playedS  = "played_s"
        case durationS = "duration_s"
        case completed, started
    }
}

struct OverlayRequest: Encodable, Sendable {  // internal: wire contract under test
    var starred: Bool? = nil
    var deleted: Bool? = nil
    var tags: [String]? = nil
    var removedTags: [String]? = nil
    var bookmarks: [Bookmark]? = nil
    var title: String? = nil

    enum CodingKeys: String, CodingKey {
        case starred, deleted, tags, bookmarks, title
        case removedTags = "removed_tags"
    }
}

private struct PlaybackActiveRequest: Encodable {
    let source: String
    let ts: String
}

/// Body for POST /episode/resume — the draft render ts to continue from.
private struct ResumeRequest: Encodable {
    let fromTS: String
    let clientRef = DaemonClient.clientRef
    enum CodingKeys: String, CodingKey { case fromTS = "from_ts", clientRef = "client_ref" }
}

/// Empty JSON body for endpoints whose target lives in the URL (episode ctrl).
private struct EmptyBody: Encodable {}

// Optional fields: the synthesized encoder uses encodeIfPresent, so a nil
// field is omitted from the JSON (leaving that key unchanged on the daemon).
// An empty-string defaultVoice IS sent — that clears the voice server-side.
private struct ConfigUpdateRequest: Encodable {
    let defaultBackend: String?
    let defaultVoice: String?
    var sayThresholdChars: Int? = nil

    enum CodingKeys: String, CodingKey {
        case defaultBackend = "default_backend"
        case defaultVoice = "default_voice"
        case sayThresholdChars = "say_threshold_chars"
    }
}

// MARK: - Response models

struct HealthResponse: Decodable {
    let status: String
    let version: String?
    let queue: Queue?
    struct Queue: Decodable {
        /// Seconds the current long-form episode has run; nil when none is.
        let episodeRunningS: Double?
        enum CodingKeys: String, CodingKey { case episodeRunningS = "episode_running_s" }
    }
}

/// GET /stats. `lifetime` never decreases (deleting recordings doesn't lower
/// it); `library` is what is on disk now.
struct StatsResponse: Decodable, Sendable {
    struct Lifetime: Decodable, Sendable {
        let renders: Int
        let chars: Int
        let words: Int
        let durationS: Double
        let bytes: Int
        let since: String?   // ts of the earliest render counted; nil when none
        enum CodingKeys: String, CodingKey {
            case renders, chars, words, bytes, since
            case durationS = "duration_s"
        }
    }
    struct Library: Decodable, Sendable {
        let renders: Int
        let durationS: Double
        let bytes: Int
        enum CodingKeys: String, CodingKey {
            case renders, bytes
            case durationS = "duration_s"
        }
    }
    let lifetime: Lifetime
    let library: Library
}

struct ConfigResponse: Decodable {
    let sayThresholdChars: Int?
    let backends: [Backend]?
    let defaultBackend: String?
    let defaultVoice: String?
    let archiveRoot: String?
    // Present on POST /config when an env var shadows the written value.
    let warnings: [String]?
    enum CodingKeys: String, CodingKey {
        case backends, warnings
        case sayThresholdChars = "say_threshold_chars"
        case defaultBackend = "default_backend"
        case defaultVoice = "default_voice"
        case archiveRoot = "archive_root"
    }
}

struct HistoryResponse: Decodable {
    let entries: [VoiceEntry]
}

struct RenderResponse: Decodable {
    let archiveName: String?
    let archivePath: String?
    let ts: String?
    let chars: Int?
    let bytes: Int?
    // Set (true) when a streaming render was cancelled mid-flight — the daemon
    // returns 200 with no archive in that case.
    let cancelled: Bool?
    let episodeID: String?
    enum CodingKeys: String, CodingKey {
        case ts, chars, bytes, cancelled
        case archiveName = "archive_name"
        case archivePath = "archive_path"
        case episodeID = "episode_id"
    }
}

// Minimal acknowledge shape for /episode/* control POSTs. Decoding `ok`
// keeps response-shape validation; callers don't consume the fields.
struct EpisodeControlResponse: Decodable {
    let ok: Bool
}
