// Wire-contract tests for the previously-uncovered cores:
// SSE frame parsing (SSELineParser), SSE event decoding (decodeEvent), the
// daemon request encodings (snake_case keys, nil-dropping, pinned mode), and
// the canonical tag sanitizer.

import Foundation
import Testing
@testable import VoiceSay

@Suite("SSELineParser")
struct SSELineParserTests {

    @Test("a full event/data/blank frame yields (name, data) once")
    func basicFrame() {
        var p = SSELineParser()
        #expect(p.consume("event: render") == nil)
        #expect(p.consume("data: {\"ts\":\"t1\"}") == nil)
        let frame = p.consume("")
        #expect(frame?.name == "render")
        #expect(frame?.data == "{\"ts\":\"t1\"}")
        // Accumulator resets — an immediate blank line yields nothing.
        #expect(p.consume("") == nil)
    }

    @Test("multi-line data joins with newline, per SSE spec")
    func multiLineData() {
        var p = SSELineParser()
        _ = p.consume("data: line one")
        _ = p.consume("data: line two")
        let frame = p.consume("")
        #expect(frame?.data == "line one\nline two")
        #expect(frame?.name == "message")   // no event: field → default name
    }

    @Test("comment lines and unknown fields are ignored; id sets lastEventId")
    func commentsAndId() {
        var p = SSELineParser()
        #expect(p.consume(":keepalive") == nil)
        _ = p.consume("id: 42")
        _ = p.consume("retry: 1000")        // unknown field → ignored
        #expect(p.lastEventId == "42")
        #expect(p.consume("") == nil)       // no data accumulated → no frame
    }

    @Test("a reconnect drops a half-received frame but keeps the last event id")
    func reconnectDiscardsPendingFrame() {
        var p = SSELineParser()
        _ = p.consume("id: 7")
        _ = p.consume("event: render")
        _ = p.consume("data: {\"ts\":\"cut-")        // connection drops here
        p.discardPendingFrame()                       // next connectOnce
        #expect(p.lastEventId == "7")
        _ = p.consume("event: snapshot")
        _ = p.consume("data: {}")
        let frame = p.consume("")
        #expect(frame?.name == "snapshot")
        #expect(frame?.data == "{}")
    }

    @Test("a blank frame without data emits nothing (keepalive pattern)")
    func keepaliveEmitsNothing() {
        var p = SSELineParser()
        _ = p.consume("event: ping")
        #expect(p.consume("") == nil)
    }

    @Test("decodeEvent maps known names to typed events and unknown to .other")
    func decodeEventMapping() {
        // Real wire shape: every event carries the envelope (id + type).
        let progress = EventStreamReader.decodeEvent(
            name: "progress",
            data: "{\"id\":7,\"type\":\"progress\",\"ts\":\"t1\",\"progress\":{\"played_s\":3.5,\"duration_s\":10}}")
        guard case .progress(let ev)? = progress else {
            Issue.record("expected .progress, got \(String(describing: progress))")
            return
        }
        #expect(ev.ts == "t1")
        #expect(ev.progress.playedS == 3.5)

        let other = EventStreamReader.decodeEvent(
            name: "future_event", data: "{\"id\":8,\"type\":\"future_event\"}")
        guard case .other? = other else {
            Issue.record("expected .other, got \(String(describing: other))")
            return
        }

        #expect(EventStreamReader.decodeEvent(name: "render", data: "not json") == nil)
    }

    @Test("decodeEvent maps every named daemon event to its typed case")
    func decodeEventAllNamedCases() {
        let entryJSON = #"{"ts":"t","backend":"qwen3","duration_s":10,"text":"x"}"#
        let fixtures: [(name: String, data: String, expect: String)] = [
            ("snapshot", #"{"id":1,"type":"snapshot","history":[\#(entryJSON)],"progress":{}}"#, "snapshot"),
            ("render", #"{"id":2,"type":"render","ts":"t2","entry":\#(entryJSON)}"#, "render"),
            ("progress", #"{"id":3,"type":"progress","ts":"t3","progress":{"played_s":1,"duration_s":2,"play_count":1,"completed":false}}"#, "progress"),
            ("overlay", #"{"id":4,"type":"overlay","ts":"t4","overlay":{"starred":true}}"#, "overlay"),
            ("playback_active", #"{"id":5,"type":"playback_active","source":"cli","ts":"t5"}"#, "playbackActive"),
            ("episode_start", #"{"id":6,"type":"episode_start","episode_id":"e1","total_chunks":3,"predicted_total_s":42.5,"chars":757,"backend":"qwen3","voice":"v"}"#, "episodeStart"),
            ("chunk_ready", #"{"id":7,"type":"chunk_ready","episode_id":"e1","seq":1,"total_chunks":3,"chunk_path":"/tmp/c1.wav","chunk_duration_s":12,"cumulative_audio_s":12}"#, "chunkReady"),
            ("episode_complete", #"{"id":8,"type":"episode_complete","episode_id":"e1","ts":"t8","archive_path":"/a/b.mp3","duration_s":36.2}"#, "episodeComplete"),
            ("episode_cancelled", #"{"id":9,"type":"episode_cancelled","episode_id":"e1"}"#, "episodeCancelled"),
            ("episode_error", #"{"id":10,"type":"episode_error","episode_id":"e1","stage":"render","message":"boom"}"#, "episodeError"),
        ]
        for f in fixtures {
            let got = Self.caseLabel(EventStreamReader.decodeEvent(name: f.name, data: f.data))
            #expect(got == f.expect, "'\(f.name)' decoded to .\(got), expected .\(f.expect)")
        }
    }

    @Test("episode_start optionals: older daemons omit text/prefix_audio_s; both survive when present")
    func episodeStartOptionals() {
        let bare = EventStreamReader.decodeEvent(
            name: "episode_start",
            data: #"{"id":1,"type":"episode_start","episode_id":"e1","total_chunks":2,"predicted_total_s":10,"chars":178,"backend":"b","voice":"v"}"#)
        guard case .episodeStart(let old)? = bare else {
            Issue.record("expected .episodeStart, got \(String(describing: bare))")
            return
        }
        #expect(old.text == nil)
        #expect(old.prefix_audio_s == nil)

        let full = EventStreamReader.decodeEvent(
            name: "episode_start",
            data: #"{"id":2,"type":"episode_start","episode_id":"e2","total_chunks":2,"predicted_total_s":10,"chars":178,"backend":"b","voice":"v","text":"body","prefix_audio_s":4.5}"#)
        guard case .episodeStart(let new)? = full else {
            Issue.record("expected .episodeStart, got \(String(describing: full))")
            return
        }
        #expect(new.text == "body")
        #expect(new.prefix_audio_s == 4.5)
        #expect(new.client_ref == nil)                        // another client's (or old) episode

        let ours = EventStreamReader.decodeEvent(
            name: "episode_start",
            data: #"{"id":3,"type":"episode_start","episode_id":"e3","total_chunks":1,"predicted_total_s":1,"chars":5,"backend":"b","voice":"v","client_ref":"app-x"}"#)
        guard case .episodeStart(let mine)? = ours else {
            Issue.record("expected .episodeStart"); return
        }
        #expect(mine.client_ref == "app-x")
        #expect(mine.title == nil && mine.series == nil && mine.episode == nil)   // an older daemon's payload
    }

    @Test("episode_start carries the render's title / series / episode, and HistoryStore puts them on the live episode")
    @MainActor
    func episodeStartIdentity() throws {
        let ev = try #require(EventStreamReader.decodeEvent(
            name: "episode_start",
            data: #"{"id":4,"type":"episode_start","episode_id":"e4","total_chunks":12,"predicted_total_s":925,"chars":16472,"backend":"remote","voice":"v","text":"Body.","prefix_audio_s":0,"title":"Attention from Scratch","series":"Series A","episode":181}"#))
        guard case .episodeStart(let start) = ev else {
            Issue.record("expected .episodeStart, got \(ev)"); return
        }
        #expect(start.title == "Attention from Scratch")
        #expect(start.series == "Series A")
        #expect(start.episode == 181)

        let store = HistoryStore(connect: false)
        store.apply(event: ev)
        let ep = try #require(store.streamingEpisode)
        #expect(ep.hasTitle && ep.displayTitle == "Attention from Scratch")
        #expect(ep.identityMetaLine.hasPrefix("Series A · 181 · v · remote · "))
        #expect(ep.identityMetaLine.hasSuffix(" · from the CLI"))      // no client_ref → another client's
    }

    private static func caseLabel(_ e: DaemonEvent?) -> String {
        switch e {
        case .snapshot:         "snapshot"
        case .render:           "render"
        case .progress:         "progress"
        case .overlay:          "overlay"
        case .playbackActive:   "playbackActive"
        case .episodeStart:     "episodeStart"
        case .chunkReady:       "chunkReady"
        case .episodeComplete:  "episodeComplete"
        case .episodeCancelled: "episodeCancelled"
        case .episodeError:     "episodeError"
        case .other:            "other"
        case nil:               "nil"
        }
    }
}

@Suite("Daemon request encodings")
struct RequestEncodingTests {

    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("RenderRequest pins mode=stream and carries this app's client_ref")
    func renderRequestPinsStream() throws {
        let obj = try json(RenderRequest(text: "hi", backend: "qwen3", voice: "v",
                                         speed: 1.0, tags: ["a"]))
        #expect(obj["mode"] as? String == "stream")
        #expect(obj["client_ref"] as? String == DaemonClient.clientRef)
        #expect(obj["title"] == nil)                         // nil overlay fields stay absent
        #expect(obj["text"] as? String == "hi")
        #expect(obj["backend"] as? String == "qwen3")
    }

    @Test("ProgressRequest uses snake_case keys and omits nil completed (heartbeat contract)")
    func progressHeartbeatOmitsCompleted() throws {
        let heartbeat = try json(ProgressRequest(playedS: 3.5, durationS: 10,
                                                 completed: nil, started: false))
        #expect(heartbeat["played_s"] as? Double == 3.5)
        #expect(heartbeat["duration_s"] as? Double == 10)
        // nil completed MUST be absent — the daemon preserves its latch.
        #expect(heartbeat["completed"] == nil)

        let latch = try json(ProgressRequest(playedS: 9.5, durationS: 10,
                                             completed: true, started: false))
        #expect(latch["completed"] as? Bool == true)
    }

    @Test("OverlayRequest drops nil fields and maps removedTags to removed_tags")
    func overlayNilDropping() throws {
        let starOnly = try json(OverlayRequest(starred: true, deleted: nil, tags: nil,
                                               removedTags: nil, bookmarks: nil, title: nil))
        #expect(starOnly.keys.sorted() == ["starred"])

        let tagWrite = try json(OverlayRequest(starred: nil, deleted: nil, tags: ["x"],
                                               removedTags: ["y"], bookmarks: nil, title: nil))
        #expect(tagWrite["removed_tags"] as? [String] == ["y"])
        #expect(tagWrite["tags"] as? [String] == ["x"])
    }

    @Test("OverlayRequest remaining fields: deleted/bookmarks/title encode when set, drop when nil; Bookmark carries id/position/note")
    func overlayRemainingFields() throws {
        let write = try json(OverlayRequest(starred: nil, deleted: true, tags: nil,
                                            removedTags: nil,
                                            bookmarks: [Bookmark(id: "b1", position: 3.25, note: "n")],
                                            title: "Title"))
        #expect(write.keys.sorted() == ["bookmarks", "deleted", "title"])
        #expect(write["deleted"] as? Bool == true)
        #expect(write["title"] as? String == "Title")
        let bm = try #require((write["bookmarks"] as? [[String: Any]])?.first)
        #expect(bm["id"] as? String == "b1")
        #expect(bm["position"] as? Double == 3.25)
        #expect(bm["note"] as? String == "n")
    }
}

@Suite("TagText.sanitized")
struct TagTextTests {

    @Test("canonical form: trim, lowercase, hyphenate, strip punctuation, collapse")
    func canonicalization() {
        #expect(TagText.sanitized("Series A") == "series-a")
        #expect(TagText.sanitized("  Weird__Tag!!  ") == "weird-tag")
        #expect(TagText.sanitized("A--B") == "a-b")
        #expect(TagText.sanitized("already-clean-1") == "already-clean-1")
    }

    @Test("degenerate inputs collapse to empty (= invalid)")
    func degenerate() {
        #expect(TagText.sanitized("---") == "")
        #expect(TagText.sanitized("!!!") == "")
        #expect(TagText.sanitized("") == "")
    }
}

@Suite("GET /stats")
struct StatsDecodeTests {
    @Test("decodes lifetime + library, int or float duration")
    func decodes() throws {
        let json = #"""
        {"lifetime": {"renders": 1287, "chars": 2345678, "words": 401234,
                      "duration_s": 152345.6, "bytes": 9876543210,
                      "since": "2026-05-01T09:12:44.123456+03:00"},
         "library": {"renders": 412, "duration_s": 137520, "bytes": 6100000000}}
        """#
        let s = try Wire.decoder.decode(StatsResponse.self, from: Data(json.utf8))
        #expect(s.lifetime.renders == 1287)
        #expect(s.lifetime.words == 401234)
        #expect(fmtHours(s.lifetime.durationS) == "42.3")
        #expect(s.lifetime.since?.prefix(10) == "2026-05-01")
        #expect(s.library.renders == 412 && s.library.bytes == 6100000000)
        #expect(fmtHours(s.library.durationS) == "38.2")
        #expect(fmtSinceDate("not-a-date") == "not-a-date")
    }

    @Test("since is null before any render")
    func nullSince() throws {
        let json = #"{"lifetime": {"renders": 0, "chars": 0, "words": 0, "duration_s": 0.0, "bytes": 0, "since": null}, "library": {"renders": 0, "duration_s": 0, "bytes": 0}}"#
        let s = try Wire.decoder.decode(StatsResponse.self, from: Data(json.utf8))
        #expect(s.lifetime.since == nil)
        #expect(s.library.renders == 0)
    }
}

@Suite("episode_error saved draft")
@MainActor
struct EpisodeErrorSavedTests {

    private func decode(_ json: String) -> DaemonEpisodeErrorEvent? {
        guard case .episodeError(let ev)? = EventStreamReader.decodeEvent(name: "episode_error", data: json)
        else { return nil }
        return ev
    }

    @Test("a failure that kept a draft says so; one that kept nothing doesn't")
    func savedDraftBanner() {
        let base = "\"id\":1,\"type\":\"episode_error\",\"episode_id\":\"e\",\"stage\":\"tts\",\"message\":\"backend died\""
        let draft = decode("{\(base),\"saved_ts\":\"t1\",\"partial\":true}")
        #expect(draft?.saved_ts == "t1")
        #expect(HistoryStore.episodeErrorText(draft!).contains("saved as a draft"))
        let whole = decode("{\(base),\"saved_ts\":\"t2\",\"partial\":false}")
        #expect(HistoryStore.episodeErrorText(whole!).hasSuffix("the episode was saved."))
        let none = decode("{\(base),\"saved_ts\":null,\"partial\":null}")
        #expect(HistoryStore.episodeErrorText(none!) == "render error (tts): backend died")
        let legacy = decode("{\(base)}")                 // older daemon: no fields
        #expect(legacy?.saved_ts == nil)
    }
}

@Suite("Health wire contract")
struct HealthWireTests {
    @Test("/health queue: running episode seconds, null when idle, absent on old daemons")
    func queue() throws {
        func decode(_ s: String) throws -> HealthResponse {
            try JSONDecoder().decode(HealthResponse.self, from: Data(s.utf8))
        }
        #expect(try decode(#"{"status":"ok","queue":{"waiting":0,"episode_running_s":12.5}}"#).queue?.episodeRunningS == 12.5)
        let idle = try decode(#"{"status":"ok","queue":{"waiting":0,"episode_running_s":null}}"#)
        #expect(idle.queue != nil && idle.queue?.episodeRunningS == nil)
        #expect(try decode(#"{"status":"ok"}"#).queue == nil)
    }
}

@Suite("History row wire contract")
struct HistoryRowWireTests {
    @Test("a /history row still decodes with the daemon's format field, which the client ignores")
    func formatFieldIgnored() throws {
        let row = #"{"ts":"t1","backend":"kokoro","voice":"af_heart","format":"mp3","chars":5,"duration_s":1.5,"text":"hello"}"#
        let e = try JSONDecoder().decode(VoiceEntry.self, from: Data(row.utf8))
        #expect(e.ts == "t1")
        #expect(e.voice == "af_heart")
        #expect(e.durationS == 1.5)
    }
}

@Suite("Backend wire contract")
struct BackendWireTests {
    private func decode(_ json: String) throws -> Backend {
        try JSONDecoder().decode(Backend.self, from: Data(json.utf8))
    }

    @Test("a backend's url from /config is where it is shown and probed; without one, 127.0.0.1:port")
    func urlOrLoopback() throws {
        let remote = try decode(##"{"id":"gpu","label":"GPU","port":443,"url":"https://tts.lan","default_voice":"v","voices":["v"],"supports_speed":true,"accent":"#888888"}"##)
        #expect(remote.baseURL?.absoluteString == "https://tts.lan")
        #expect(remote.hostPort == "tts.lan:443")
        let local = try decode(##"{"id":"kokoro","label":"Kokoro","port":8000,"default_voice":"af_heart","voices":["af_heart"],"supports_speed":true,"accent":"#6ea8ff"}"##)
        #expect(local.baseURL?.absoluteString == "http://127.0.0.1:8000")
        #expect(local.hostPort == "127.0.0.1:8000")
    }
}
