// EventStreamReader — SSE consumer over URLSession + delegate-based
// data task.
//
// macOS's `URLSession.bytes(for:)` buffers Server-Sent Events streams
// — small events (single overlay POST, keepalive comment) sit in the
// CFNetwork read buffer until either ~16 KB accumulate or the
// connection closes. We never see them in real time. The delegate
// path (`urlSession(_:dataTask:didReceive:)`) hands us each chunk as
// it arrives, so a single 60-byte overlay event dispatches immediately.
//
// Connects to the daemon's /events endpoint, parses per
// https://html.spec.whatwg.org/multipage/server-sent-events.html.
// Tracks `lastEventId` so a reconnect sends `Last-Event-ID:` and the
// daemon replays buffered events (or sends a snapshot if our id has
// aged out of the ring).
//
// Auto-reconnects with exponential backoff on transport failure; lives for
// the app's lifetime (HistoryStore starts it once).

import Foundation
import os

actor EventStreamReader {
    private let url: URL
    private var task: Task<Void, Never>? = nil
    private var backoff = ReconnectBackoff()

    init(url: URL) {
        self.url = url
    }

    /// Starts (or restarts) the read loop. Multiple `start` calls are idempotent.
    func start(onEvent: @escaping @Sendable (DaemonEvent) -> Void,
               onConnectChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.runLoop(onEvent: onEvent, onConnectChange: onConnectChange)
        }
    }

    private func runLoop(onEvent: @escaping @Sendable (DaemonEvent) -> Void,
                         onConnectChange: @escaping @Sendable (Bool) -> Void) async {
        while !Task.isCancelled {
            // Set once this attempt's stream opened: a drop after a working
            // connection (daemon restart) starts the backoff over instead of
            // inheriting the delay earlier failed attempts built up.
            let connected = OSAllocatedUnfairLock(initialState: false)
            do {
                try await connectOnce(onEvent: onEvent, onConnectChange: { up in
                    if up { connected.withLock { $0 = true } }
                    onConnectChange(up)
                })
                try? await Task.sleep(nanoseconds: 250_000_000)
                backoff.reset()
            } catch is CancellationError {
                return
            } catch {
                onConnectChange(false)
                let delay = backoff.nextDelay(afterConnected: connected.withLock { $0 })
                Log.sse.error("stream dropped, reconnect in \(delay, format: .fixed(precision: 0))s: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func connectOnce(onEvent: @escaping @Sendable (DaemonEvent) -> Void,
                             onConnectChange: @escaping @Sendable (Bool) -> Void) async throws {
        var req = URLRequest(url: url)
        // Big-but-finite — URLRequest treats 0 as the system default (60s),
        // which would tear the stream down on the first quiet minute. The
        // daemon sends `:keepalive\n\n` every 15s so any value above
        // that keeps the pipe alive; 24h is just a generous ceiling.
        req.timeoutInterval = 86400
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // Disable HTTP cache for the stream so reconnects always hit the
        // daemon fresh.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A frame the last connection left half-received must not prefix the
        // first frame of this one (SSE: a reconnect discards the data buffer;
        // the last event id is kept).
        parser.discardPendingFrame()
        if let lastEventId = parser.lastEventId {
            req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 86400
        cfg.timeoutIntervalForResource = 86400
        cfg.waitsForConnectivity = false

        // Lines flow delegate → AsyncStream → ONE consumer task, so SSE
        // frame ordering is guaranteed. (The previous shape spawned an
        // unstructured Task per line and leaned on incidental FIFO — two
        // racing hops could interleave an `event:`/`data:`/blank triple and
        // mis-pair the accumulator.) URLSession's serial delegate queue
        // makes the yields ordered; the single `for await` preserves that.
        let (lines, lineCont) = AsyncStream<String>.makeStream()
        let consumer = Task { [weak self] in
            for await line in lines {
                await self?.feedLine(line, onEvent: onEvent)
            }
        }
        // Suspend until the stream ends. The delegate calls into the
        // continuation when the request finishes (or fails). Then let the
        // consumer drain what was already yielded, so no line of this
        // connection reaches the parser after the next one has reset it.
        var failure: Error? = nil
        do {
            try await stream(req, cfg: cfg, lineCont: lineCont, onConnectChange: onConnectChange)
        } catch {
            failure = error
        }
        lineCont.finish()
        await consumer.value
        if let failure { throw failure }
    }

    private func stream(_ req: URLRequest, cfg: URLSessionConfiguration,
                        lineCont: AsyncStream<String>.Continuation,
                        onConnectChange: @escaping @Sendable (Bool) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = SSEDelegate(
                onConnected: {
                    onConnectChange(true)
                },
                onLine: { line in
                    lineCont.yield(line)
                },
                onFinish: { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            // The session holds its delegate strongly until the delegate's
            // didCompleteWithError invalidates it.
            session.dataTask(with: req).resume()
        }
    }

    /// SSE frame accumulator — pure parser (SSELineParser below) held on the
    /// actor; the single AsyncStream consumer feeds it in order.
    private var parser = SSELineParser()

    private func feedLine(_ line: String, onEvent: @escaping @Sendable (DaemonEvent) -> Void) {
        guard let frame = parser.consume(line) else { return }
        if let event = Self.decodeEvent(name: frame.name, data: frame.data) {
            onEvent(event)
        } else {
            // A named event whose payload didn't decode is a wire-contract
            // break worth seeing in `log stream`, not silence.
            Log.sse.error("undecodable '\(frame.name, privacy: .public)' frame (\(frame.data.count) bytes)")
        }
    }

    /// Decode one completed SSE frame into a typed DaemonEvent (nil = not
    /// decodable). Pure + static so the event-decoding contract is directly
    /// unit-testable.
    nonisolated static func decodeEvent(name: String, data: String) -> DaemonEvent? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        let d = Wire.decoder
        guard let env = try? d.decode(DaemonEventEnvelope.self, from: bytes) else { return nil }
        switch name {
        case "snapshot":         return (try? d.decode(DaemonSnapshotEvent.self, from: bytes)).map(DaemonEvent.snapshot)
        case "render":           return (try? d.decode(DaemonRenderEvent.self, from: bytes)).map(DaemonEvent.render)
        case "progress":         return (try? d.decode(DaemonProgressEvent.self, from: bytes)).map(DaemonEvent.progress)
        case "overlay":          return (try? d.decode(DaemonOverlayEvent.self, from: bytes)).map(DaemonEvent.overlay)
        case "playback_active":  return (try? d.decode(DaemonPlaybackActiveEvent.self, from: bytes)).map(DaemonEvent.playbackActive)
        case "episode_start":    return (try? d.decode(DaemonEpisodeStartEvent.self, from: bytes)).map(DaemonEvent.episodeStart)
        case "chunk_ready":      return (try? d.decode(DaemonChunkReadyEvent.self, from: bytes)).map(DaemonEvent.chunkReady)
        case "episode_complete": return (try? d.decode(DaemonEpisodeCompleteEvent.self, from: bytes)).map(DaemonEvent.episodeComplete)
        case "episode_cancelled": return (try? d.decode(DaemonEpisodeCancelledEvent.self, from: bytes)).map(DaemonEvent.episodeCancelled)
        case "episode_error":    return (try? d.decode(DaemonEpisodeErrorEvent.self, from: bytes)).map(DaemonEvent.episodeError)
        default:                 return .other(env)
        }
    }
}

// MARK: - SSELineParser

/// Pure SSE frame accumulator (the WHATWG server-sent-events subset the
/// daemon emits: `id:` / `event:` / `data:` fields, `:` comments, blank-line
/// frame terminator, multi-line data joined with \n). Extracted from the
/// actor so the parsing contract is directly unit-testable.
/// Reconnect delay for the SSE stream: doubles per failed attempt up to
/// `cap`, and starts over at `initial` when the attempt that failed had
/// connected first.
struct ReconnectBackoff: Equatable, Sendable {
    static let initial: Double = 1
    static let cap: Double = 30
    private(set) var current: Double = Self.initial

    /// The delay to wait after a failed attempt; advances the next one.
    mutating func nextDelay(afterConnected connected: Bool) -> Double {
        if connected { current = Self.initial }
        let delay = current
        current = min(Self.cap, current * 2)
        return delay
    }

    mutating func reset() { current = Self.initial }
}

struct SSELineParser {
    private(set) var lastEventId: String? = nil
    private var pendingEventName = ""
    private var pendingEventData = ""

    /// Drop a frame in progress (called per new connection); keeps
    /// `lastEventId`.
    mutating func discardPendingFrame() {
        pendingEventName = ""
        pendingEventData = ""
    }

    /// Feed one line. Returns the completed (name, data) frame when `line`
    /// is the blank separator closing a frame with data; nil otherwise.
    mutating func consume(_ line: String) -> (name: String, data: String)? {
        if line.isEmpty {
            defer { pendingEventName = ""; pendingEventData = "" }
            guard !pendingEventData.isEmpty else { return nil }
            return (pendingEventName.isEmpty ? "message" : pendingEventName, pendingEventData)
        }
        if line.hasPrefix(":") { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "id":    lastEventId = value
        case "event": pendingEventName = value
        case "data":  pendingEventData += pendingEventData.isEmpty ? value : "\n\(value)"
        default: break
        }
        return nil
    }
}

// MARK: - URLSessionDataDelegate

/// Receives raw chunks from URLSession and emits parsed SSE lines.
/// Marked @unchecked Sendable because the closures are immutable after
/// init and the line buffer is only mutated inside the delegate queue
/// (URLSession invokes delegate methods on a single internal queue).
private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onConnected: @Sendable () -> Void
    private let onLine: @Sendable (String) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private var connected = false
    private var carry = Data()  // bytes from a partial line

    init(onConnected: @escaping @Sendable () -> Void,
         onLine: @escaping @Sendable (String) -> Void,
         onFinish: @escaping @Sendable (Error?) -> Void) {
        self.onConnected = onConnected
        self.onLine = onLine
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            completionHandler(.cancel)
            return
        }
        if !connected {
            connected = true
            onConnected()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        carry.append(data)
        // Split on LF. The SSE spec treats both LF and CRLF as line breaks;
        // we strip trailing CR after the split.
        while let nlIdx = carry.firstIndex(of: 0x0A) {
            var lineData = carry[..<nlIdx]
            // Drop trailing CR if present.
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(data: Data(lineData), encoding: .utf8) ?? ""
            // Remove consumed bytes (line + the LF).
            carry.removeSubrange(...nlIdx)
            onLine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Surface to the actor's continuation. Invalidate the session so
        // we don't leak threads; the actor's runLoop will reconnect via
        // a fresh session on the next iter.
        session.invalidateAndCancel()
        onFinish(error)
    }
}

// MARK: - Event payloads

enum DaemonEvent: Sendable {
    case snapshot(DaemonSnapshotEvent)
    case render(DaemonRenderEvent)
    case progress(DaemonProgressEvent)
    case overlay(DaemonOverlayEvent)
    case playbackActive(DaemonPlaybackActiveEvent)
    // Streaming (play-while-render) coordination events.
    case episodeStart(DaemonEpisodeStartEvent)
    case chunkReady(DaemonChunkReadyEvent)
    case episodeComplete(DaemonEpisodeCompleteEvent)
    case episodeCancelled(DaemonEpisodeCancelledEvent)
    case episodeError(DaemonEpisodeErrorEvent)
    case other(DaemonEventEnvelope)
}

struct DaemonEventEnvelope: Decodable, Sendable {
    let id: Int
    let type: String
}

struct DaemonSnapshotEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let history: [VoiceEntry]
    let progress: [String: ProgressInfo]
    let overlays: [String: Overlay]?
}

struct DaemonRenderEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let ts: String
    let entry: VoiceEntry
}

struct DaemonProgressEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let ts: String
    let progress: ProgressInfo
}

struct DaemonOverlayEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let ts: String
    let overlay: Overlay
}

struct DaemonPlaybackActiveEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let source: String
    let ts: String
}

// MARK: - Streaming (play-while-render) event payloads

/// Broadcast once before the chunk loop. `episode_id` is a fresh
/// secrets.token_hex(8) string (NOT a ts). `predicted_total_s` = chars/17.8.
struct DaemonEpisodeStartEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let episode_id: String
    let total_chunks: Int
    let predicted_total_s: Double
    let chars: Int
    let backend: String
    let voice: String
    // The full chunked transcript that will be read (optional — older daemons
    // omit it; the read-while-rendering view then degrades to no body text).
    let text: String?
    // Audio seconds already in the draft prefix on a RESUME (the prefix is
    // concatenated server-side, not streamed), so the client seeds its
    // render-head + playhead into full-text space. nil/0 for a fresh render.
    let prefix_audio_s: Double?
    // The sender's client_ref, if it sent one (DaemonClient.clientRef = ours).
    let client_ref: String?
    // The row-to-be's title / series / episode, each only when the render set
    // it (optional — older daemons never send them).
    let title: String?
    let series: String?
    let episode: Int?
}

/// Broadcast after each transient chunk file lands. `chunk_path` is an
/// absolute path to a playable wav; `cumulative_audio_s` is the running
/// render-head.
struct DaemonChunkReadyEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let episode_id: String
    let seq: Int
    let total_chunks: Int
    let chunk_path: String
    let chunk_duration_s: Double
    let cumulative_audio_s: Double
    // Cumulative char offset into episode_full_text rendered so far — the
    // render-head the read-while-rendering view grays past (optional).
    let rendered_chars: Int?
}

/// Broadcast after render_longform returns. `ts` is the canonical
/// renders-row PK (String, matches VoiceEntry.id). `duration_s` is the
/// true probed concat duration (snaps the predicted total).
struct DaemonEpisodeCompleteEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let episode_id: String
    let ts: String
    let archive_path: String
    let duration_s: Double
    let save_and_stop: Bool?
}

/// Terminal event when a streaming render is cancelled — no canonical row.
struct DaemonEpisodeCancelledEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let episode_id: String
}

/// Terminal event when a streaming render fails mid-flight.
struct DaemonEpisodeErrorEvent: Decodable, Sendable {
    let id: Int
    let type: String
    let episode_id: String
    let stage: String
    let message: String
    /// Row the finished chunks were saved as (nil = nothing had finished).
    let saved_ts: String?
    /// true = a resumable draft; false = the whole episode (only the join failed).
    let partial: Bool?
}
