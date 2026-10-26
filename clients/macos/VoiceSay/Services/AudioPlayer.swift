// AudioPlayer — AVAudioPlayer with MPNowPlayingInfoCenter so macOS Media
// keys, Control Center "Now Playing", Touch Bar, AirPlay, and headphone
// transport buttons all drive the same audio.
//
// Responsibilities beyond playback:
//   1. Per-entry RESUME — seeks to entry.progress.playedS on play.
//   2. PROGRESS PERSISTENCE — POSTs every ~3s and on pause/stop/swap to
//      the voice-say daemon's /progress/<ts> endpoint, so progress survives
//      restarts and is visible to the CLI and any other daemon client.
//   3. SINGLE-PLAYER COORDINATION — on play, kills any active CLI-spawned
//      mpv via voice-ctl and POSTs /playback/active so other surfaces
//      pause. On a `playback_active` SSE event from another source,
//      stops itself. Together this prevents doubled audio when both
//      VoiceSay's AVAudioPlayer and the CLI's mpv are alive.

import Foundation
import AVFoundation
import MediaPlayer
import Observation
import AppKit

extension Notification.Name {
    /// Fired by HistoryStore when another source claims playback.
    static let playbackTakenByOther = Notification.Name("playbackTakenByOther")
    /// Header button / ⌥⌘S → ContentView shows or hides the sidebar.
    static let toggleSidebar = Notification.Name("toggleSidebar")
}

@MainActor
@Observable
final class AudioPlayer: NSObject {
    /// Called when an entry plays to its natural end (not on stop) — App wires
    /// it to HistoryStore.playNextInSeries (auto-advance).
    @ObservationIgnored var onFinished: ((VoiceEntry) -> Void)?

    /// Sleep timer: pause after some minutes of PLAYING (fading out over the
    /// last `sleepFadeS`), or when the current entry ends. nil = off. The
    /// minutes count down only while audio plays, so a pause doesn't use them up.
    enum SleepTimer: Equatable, Hashable { case minutes(Int), endOfEpisode }
    private(set) var sleepTimer: SleepTimer? = nil
    private(set) var sleepRemaining: TimeInterval? = nil
    @ObservationIgnored private var sleepTickAt: Date? = nil
    nonisolated static let sleepFadeS: TimeInterval = 10

    func setSleepTimer(_ t: SleepTimer?) {
        sleepTimer = t
        if case .minutes(let m) = t {
            sleepRemaining = TimeInterval(m * 60)
        } else {
            sleepRemaining = nil
        }
        sleepTickAt = nil
        player?.volume = 1
        queuePlayer?.volume = 1
    }

    /// One sleep-timer step, from whichever clock drives playback (the file
    /// tick or the live-render queue observer): spend the time since the last
    /// step while playing, fade the volume over the last seconds, and pause
    /// at zero, keeping the place.
    private func advanceSleepTimer() {
        let now = Date()
        let elapsed = sleepTickAt.map { now.timeIntervalSince($0) } ?? 0
        sleepTickAt = now
        guard let remaining = sleepRemaining, isPlaying else { return }
        let left = Self.sleepCountdown(remaining, elapsed: elapsed, playing: true)
        sleepRemaining = left
        let volume = Self.sleepVolume(remaining: left, fade: Self.sleepFadeS)
        player?.volume = volume
        queuePlayer?.volume = volume
        guard left <= 0 else { return }
        if let qp = queuePlayer {
            qp.pause()
            streamUserPaused = true   // a chunk landing later must not wake it
        } else {
            player?.pause()
            flushProgress()
        }
        isPlaying = false
        setSleepTimer(nil)
        updateNowPlaying()
    }

    /// Sleep time left after a tick `elapsed` seconds long: spent only while
    /// playing; a tick gap over a second (timer stalled) counts as one second.
    nonisolated static func sleepCountdown(_ remaining: TimeInterval, elapsed: TimeInterval,
                                           playing: Bool) -> TimeInterval {
        playing ? remaining - min(1, max(0, elapsed)) : remaining
    }

    /// Player volume `remaining` seconds before the sleep deadline: full until
    /// the last `fade` seconds, then a straight ramp to silence.
    nonisolated static func sleepVolume(remaining: TimeInterval, fade: TimeInterval) -> Float {
        Float(max(0, min(1, remaining / fade)))
    }
    private(set) var activeEntry: VoiceEntry? = nil
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Entry currently being loaded — drives row-level ProgressView in the
    /// UI. Set on play() entry, cleared when the AVAudioPlayer is ready or
    /// the load failed. Race-protected: a second play() while one is in
    /// flight wins; the older load's main-actor continuation no-ops on the
    /// id mismatch.
    private(set) var loadingEntryID: String? = nil
    // Additive. The existing duration/currentTime/isPlaying are reused for
    // the streaming playhead too, so PlayerPanel's existing bindings work.
    /// Render-head for the active streaming episode — how many seconds of
    /// audio are rendered and safe to play. 0 outside stream mode.
    private(set) var renderHeadS: TimeInterval = 0
    /// EXPLICIT total denominator for the streaming path (predicted, then
    /// snapped to true duration on episode_complete). Fixes the
    /// player.duration bug — AVAudioPlayer.duration is the single-file
    /// length, meaningless for a multi-chunk stream. 0 outside stream mode.
    private(set) var episodeTotalS: TimeInterval = 0
    /// True while the queue has drained ahead of the render-head and we're
    /// waiting for the next chunk to land.
    private(set) var isBuffering: Bool = false
    var playbackRate: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: DefaultsKeys.playbackRate)
            applyRate()
            updateNowPlaying()
        }
    }

    static let speedStops: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5]

    private var player: AVAudioPlayer? = nil
    private var tickTimer: Timer? = nil
    private var nowPlayingBound = false
    private var tickCounter: Int = 0
    private let progressPostEveryTicks = 12  // 12 × 0.25s = 3s
    /// ts we've already latched "listened" (≥90%) for this session, so the tick
    /// posts completed=true once per entry rather than every tick until the SSE
    /// echo lands. Keyed by ts → no reset hook needed across entry swaps.
    private var listenedMarkedFor: String? = nil
    /// Fraction of playback that counts as "listened to completion" — green bar
    /// + virtual #completed, without playing to the exact end.
    private let listenedThreshold = 0.9

    // Parallel to the AVAudioPlayer single-file path. Exactly one of
    // `player` / `queuePlayer` is non-nil at a time; `streamMode` is the
    // gate so the two never co-drive the published vars. The single-file
    // path is left unchanged by stream mode.
    private var queuePlayer: AVQueuePlayer? = nil
    private var queueTimeObserver: Any? = nil
    private var queueEndObserver: NSObjectProtocol? = nil
    /// Title for Now Playing while streaming (no VoiceEntry exists yet).
    private var streamTitle: String = "rendering…"
    private var streamVoice: String = "voice"
    private var streamBackend: String = ""
    /// How many chunks have been enqueued — used for the buffer-lead gate.
    private var streamChunksEnqueued: Int = 0
    /// Every enqueued chunk's duration (and the resume prefix): maps the
    /// queue player's per-item clock to whole-episode time and back.
    private var streamTimeline = StreamTimeline()
    /// Our link to each enqueued chunk, by chunk index. A seek to an earlier
    /// chunk rebuilds the queue from these (a played item is gone from it).
    private var streamChunkURLs: [URL] = []
    /// The AVPlayerItems WE enqueued and still hold, with their chunk index.
    /// The end-of-item observer gates on membership (the ended item is
    /// already out of items() when the notification fires, so containment
    /// can't be asked of the queue itself). Held strongly so an identity
    /// can't be reused by a new item while a notification is in flight.
    private var streamQueued: [(item: AVPlayerItem, chunk: Int)] = []
    /// Total chunks the episode will produce (from episode_start) — lets the
    /// final/only chunk start playback when the 2-chunk lead can't be reached.
    private var streamTotalChunks: Int = 0
    /// True once playback has begun, so the initial lead-wait is told apart
    /// from a mid-playback underrun.
    private var streamStarted: Bool = false
    /// True once the daemon confirms the episode finished (episode_complete →
    /// markStreamComplete). Finalize-on-drain gates on THIS measured signal,
    /// never on the daemon's predicted_total_s estimate (a coarse chars/17.8
    /// seed computed daemon-side, which under-predicts for a slow voice →
    /// premature stop). Reset on teardown.
    private var streamDone: Bool = false
    /// True once the user explicitly paused — a freshly rendered chunk must NOT
    /// auto-resume past an explicit pause.
    private var streamUserPaused: Bool = false
    /// True exactly when the streaming sub-mode owns playback. Readable
    /// module-wide. playbackRate is threaded through the queue player too
    /// (applyRate + the playImmediately(atRate:) resume sites), so speed
    /// works during a live render.
    var streamMode: Bool { queuePlayer != nil }

    /// Unix-socket IPC server speaking a subset of mpv's protocol. Started
    /// on first successful play() so external controllers (a global hotkey
    /// → voice-ctl) can drive transport globally, as they drive the CLI's
    /// mpv. Lazy so init stays cheap and the socket only
    /// exists when VoiceSay owns playback.
    private var mpvServer: MpvCompatServer?
    private let socketPath: String

    init(socketPath: String = MpvCompatServer.socketPath) {
        self.socketPath = socketPath
        super.init()
        let saved = UserDefaults.standard.double(forKey: DefaultsKeys.playbackRate)
        if saved > 0 {
            playbackRate = Self.speedStops.min(by: { abs($0 - saved) < abs($1 - saved) }) ?? 1.0
        }
        // Sweep a stale socket left by a prior VoiceSay instance that crashed
        // before stopInternal() could unlink. Without this, voice-ctl status
        // would still report "playing" on launch. A live one belongs to
        // another running copy and stays.
        MpvCompatServer.removeIfStale(socketPath)
        bindRemoteCommands()
        NotificationCenter.default.addObserver(
            forName: .playbackTakenByOther, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        // Quit cleanup — stop() runs synchronously in the handler (a
        // scheduled Task might not run before the process exits): clears
        // the system Now Playing entry and unlinks the mpv-compat socket so
        // Control Center and voice-ctl never see a ghost of a dead app.
        // The final progress POST it kicks off is fire-and-forget
        // (Task.detached) — best-effort on quit; the next heartbeat after
        // relaunch reconverges the daemon's progress row.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Lazily build + start the IPC server. Called once we know VoiceSay is
    /// actually going to own playback (after AVAudioPlayer prepares).
    // MARK: - mpv-compat IPC server (external transport control)

    private func ensureMpvServerRunning() {
        if mpvServer == nil {
            mpvServer = MpvCompatServer(path: socketPath) { [weak self] cmd in
                guard let self else { return }
                Task { @MainActor in self.handleMpvCommand(cmd) }
            }
        }
        mpvServer?.start()
    }

    private func shutdownMpvServer() {
        mpvServer?.stop()
    }

    /// Dispatch one parsed mpv IPC command on the main actor.
    private func handleMpvCommand(_ cmd: [Any]) {
        guard let action = cmd.first as? String else { return }
        switch action {
        case "cycle":
            if cmd.count >= 2, let prop = cmd[1] as? String, prop == "pause" {
                togglePlay()
            }
        case "seek":
            if cmd.count >= 2 {
                let n: Double? = (cmd[1] as? Double)
                    ?? (cmd[1] as? Int).map(Double.init)
                    ?? Double(String(describing: cmd[1]))
                if let n { skip(by: n) }
            }
        case "set_property":
            if cmd.count >= 3, let prop = cmd[1] as? String, prop == "pause" {
                let paused = (cmd[2] as? Bool) ?? false
                if paused, isPlaying { togglePlay() }
                if !paused, !isPlaying, (player != nil || queuePlayer != nil) { togglePlay() }
            }
        case "quit":
            stop()
        default:
            break
        }
    }


    /// Play a single entry. If `entry` matches the currently active one,
    /// toggles play/pause synchronously (no load). Otherwise stops the
    /// active track and kicks off an off-main-thread load of the new one;
    /// `loadingEntryID` is set so the row chrome can show a ProgressView
    /// instead of freezing the UI on a 60 MB MP3 decode.
    // MARK: - Single-file playback

    /// Play `entry` (toggle if it's already loaded). `startFraction` starts a
    /// fresh load at that fraction of the file instead of the saved position;
    /// `autoplay: false` loads it there paused.
    func play(_ entry: VoiceEntry, startFraction: Double? = nil, autoplay: Bool = true) {
        guard let url = entry.resolvedAudioURL() else {
            NSSound.beep()
            return
        }
        // Clicking a normal row mid-stream cleanly hands playback back to
        // the AVAudioPlayer file engine. Tear down the queue path first so
        // the two players never co-drive the published vars.
        if streamMode { teardownStreaming() }
        if activeEntry?.id == entry.id, let p = player {
            if p.isPlaying { p.pause(); isPlaying = false; flushProgress() }
            else { p.play(); isPlaying = true }
            updateNowPlaying()
            return
        }
        // Rapid-double-play guard: if a load for THIS entry is already in
        // flight, do nothing. Without this, each retry sees `player == nil`
        // (stop'd by the previous retry's stopInternal), passes isHandoff=true,
        // and fires another killExternalMpv + announcePlaybackActive HTTP
        // POST. All retries' detached tasks would also pass the loadingEntryID
        // guard and sequentially run p.play() → audible glitch.
        if loadingEntryID == entry.id { return }
        flushProgress()
        // If we're already the playback source (a queue advance or replay),
        // skip the kill-external-mpv + announce dance — both fire IPC/HTTP
        // and produce nothing useful when there is no other surface alive.
        let isHandoff = (player == nil)
        stopInternal(clearQueue: false)
        loadingEntryID = entry.id
        let ts = entry.ts
        let resumeAt = entry.progress?.playedS ?? 0

        // Capture `self` strongly into the detached task; the AudioPlayer
        // is a long-lived @StateObject so retain is fine. Using a strong
        // capture avoids the Swift 6 sendable-closure warning on `weak
        // self` rebinding across the inner `MainActor.run` boundary.
        Task.detached { [self] in
            // Off-main: kill any CLI-spawned mpv + decode the audio file.
            // Both touch disk and would block the UI on the main thread.
            if isHandoff {
                Self.killExternalMpv()
                await DaemonClient.shared.announcePlaybackActive(ts: ts)
            }
            let prepared: Result<AVAudioPlayer, Error>
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.enableRate = true
                p.prepareToPlay()
                prepared = .success(p)
            } catch {
                prepared = .failure(error)
            }
            await MainActor.run {
                // A newer play() may have superseded us — silently drop
                // this load and let the newer one win.
                guard self.loadingEntryID == entry.id else { return }
                self.loadingEntryID = nil
                switch prepared {
                case .failure:
                    NSSound.beep()
                case .success(let p):
                    p.delegate = self
                    p.rate = Float(self.playbackRate)   // speed may have changed while loading
                    if let f = startFraction {
                        p.currentTime = max(0, min(p.duration, p.duration * f))
                    } else if resumeAt > 0, resumeAt < p.duration - 1 {
                        p.currentTime = resumeAt
                    }
                    if autoplay { p.play() }
                    self.player = p
                    self.activeEntry = entry
                    self.duration = p.duration
                    self.currentTime = p.currentTime
                    self.isPlaying = autoplay
                    self.tickCounter = 0
                    self.startTick()
                    self.updateNowPlaying(reset: true)
                    if autoplay { self.postProgress(started: true) }
                    self.ensureMpvServerRunning()
                }
            }
        }
    }


    /// Begin a streaming episode. Tears down any AVAudioPlayer file path,
    /// builds an empty AVQueuePlayer, and arms the periodic time observer.
    /// Playback starts later (in enqueueChunk) once the buffer lead is met.
    // MARK: - Streaming bridge (play-while-render via AVQueuePlayer)

    func startStreaming(_ ep: StreamingEpisode, autoplay: Bool = true) {
        // Hand back any single-file playback cleanly.
        flushProgress()
        stopInternal(clearQueue: true)

        let qp = AVQueuePlayer()
        qp.actionAtItemEnd = .advance
        // Chunks are short local WAVs fed in as they render. With the default
        // stall-avoidance heuristic, play() parks in .waitingToPlayAtSpecified-
        // Rate and emits NO audio (it can't predict a stall-free playthrough of
        // a queue that's still growing) — the "play while rendering does nothing"
        // bug. Force immediate transport instead.
        qp.automaticallyWaitsToMinimizeStalling = false
        queuePlayer = qp
        streamChunksEnqueued = 0
        streamTotalChunks = ep.totalChunks
        streamStarted = false
        streamUserPaused = !autoplay
        streamTitle = "rendering…"
        streamVoice = ep.voice
        streamBackend = ep.backend
        episodeTotalS = ep.predictedTotalS
        // On a RESUME the draft prefix is already rendered + concatenated
        // server-side (not streamed), so both heads begin at the prefix offset
        // in full-text space — otherwise the bar under-fills by the prefix
        // fraction. prefixAudioS == 0 for a fresh render.
        streamTimeline = StreamTimeline(base: ep.prefixAudioS)
        streamChunkURLs = []
        streamQueued = []
        renderHeadS = ep.prefixAudioS
        currentTime = ep.prefixAudioS
        duration = ep.predictedTotalS   // best-effort; PlayerPanel uses episodeTotalS
        isBuffering = true
        isPlaying = false

        // 0.25s periodic observer mirrors the AVAudioPlayer tick cadence,
        // but the file-path tickTimer is NEVER started in stream mode —
        // exactly one clock writes currentTime.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        queueTimeObserver = qp.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            // Registered on the main queue → we ARE on the main actor at call
            // time; assert it so the @Sendable (non-isolated) observer closure
            // can touch main-actor state without a Swift 6 isolation warning.
            MainActor.assumeIsolated {
                guard let self, self.streamMode, let qp = self.queuePlayer else { return }
                // `t` is the current ITEM's time (0 at each chunk's start).
                // With no current item (drained, waiting for a chunk) the
                // playhead stays where the end-of-item handler put it.
                if let chunk = self.chunkIndex(of: qp.currentItem) {
                    self.currentTime = self.streamTimeline.position(chunk: chunk, itemTime: t.seconds)
                }
                self.advanceSleepTimer()
                self.updateNowPlaying()
            }
        }
        // Underrun detection: when the current item plays to end and the
        // queue is empty (and the episode isn't done), we've drained the
        // lead — buffer until the next chunk lands. object: nil because the
        // ended item is already removed from items() when this fires — so we
        // tag OUR items (streamQueued) and gate on membership instead,
        // keeping a foreign AVPlayerItem (none exist today) from triggering
        // a bogus underrun/finalize.
        queueEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let ended = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let ended,
                      let chunk = self.streamQueued.first(where: { $0.item === ended })?.chunk
                else { return }
                self.handleQueueItemEnded(ended, chunk: chunk)
            }
        }

        ensureMpvServerRunning()
        updateNowPlaying(reset: true)
    }

    /// Append one rendered chunk to the streaming queue. Advances the
    /// render-head and starts (or resumes from buffering) playback once
    /// enough lead is available.
    func enqueueChunk(url: URL, durationS: Double) {
        guard let qp = queuePlayer else { return }
        // Our own link: the daemon deletes its chunk files at the final concat,
        // while queued chunks may still be minutes from playing.
        let link = StreamChunkLinks.retain(url)
        streamChunkURLs.append(link)
        streamTimeline.append(durationS)
        let item = AVPlayerItem(url: link)
        streamQueued.append((item, streamChunkURLs.count - 1))
        qp.insert(item, after: nil)
        streamChunksEnqueued += 1
        renderHeadS = streamTimeline.head

        // Respect an explicit user pause — a freshly rendered chunk must not
        // resume playback the user paused; it stays paused until they resume.
        guard !streamUserPaused else { updateNowPlaying(); return }

        if !streamStarted {
            // Initial start — wait for a full chunk of LEAD (or the whole short
            // episode) so chunk N plays while chunk N+1 renders. The old 1s
            // gate started after a single multi-second chunk, so the queue
            // drained the instant chunk 1 finished — the audible seam.
            if streamChunksEnqueued >= 2 || streamChunksEnqueued >= streamTotalChunks {
                qp.playImmediately(atRate: Float(playbackRate)); isPlaying = true; isBuffering = false; streamStarted = true
                updateNowPlaying()
            }
        } else if isBuffering {
            // Mid-playback underrun recovery — the awaited chunk landed; resume.
            qp.playImmediately(atRate: Float(playbackRate)); isPlaying = true; isBuffering = false
            updateNowPlaying()
        }
    }

    /// Recalibrate the streaming total from MEASURED pace as chunks land. The
    /// initial episodeTotalS is the daemon's predicted_total_s (a chars/17.8
    /// seed) that drifts for any voice off that pace; renderHeadS ↔ rendered-chars
    /// is the voice's ACTUAL chars/sec, so the caller passes
    /// renderHeadS × totalChars / renderedChars.
    /// Clamped to never fall below the rendered head. markStreamComplete still
    /// snaps to the true probed duration at the end.
    func updateEpisodeTotal(_ seconds: TimeInterval) {
        guard streamMode, seconds > 0 else { return }
        episodeTotalS = max(renderHeadS, seconds)
    }

    /// Snap the streaming denominator to the true probed duration once the
    /// daemon reports the gapless concat is complete.
    func markStreamComplete(totalS: Double) {
        guard streamMode else { return }
        streamDone = true
        if totalS > 0 { episodeTotalS = totalS }
        // If playback already drained the last chunk and parked in `isBuffering`
        // waiting for audio that will never arrive (the episode is done),
        // finalize instead of stranding the queue + Now Playing on a dead stream
        // until the next play() — handleQueueItemEnded already fired while
        // streamDone was still false, so it won't re-finalize on its own.
        if isBuffering, let qp = queuePlayer, qp.items().isEmpty {
            finalizeStreamingPlayback()
            return
        }
        updateNowPlaying()
    }

    /// A live render that finished keeps its place: playback moves from the
    /// chunk queue to the archived file at the same second, playing or
    /// paused, so the finished row's reader, progress and controls drive it.
    /// The queue has no row, so that reader showed 0:00 while audio played.
    func handOffStream(to entry: VoiceEntry, totalS: Double) {
        guard streamMode, streamStarted, totalS > 0,
              entry.resolvedAudioURL() != nil else { return }
        play(entry, startFraction: min(currentTime / totalS, 1), autoplay: isPlaying)
    }

    /// True once the streaming buffer lead has been met (or playback is already
    /// running) — the single source for the streaming play-button enabled state,
    /// previously copy-pasted as `canPlay` / `streamCanPlay` in two views.
    var streamPlayable: Bool { isPlaying || (!isBuffering && streamStarted) }

    /// Public teardown of the streaming sub-mode — used by HistoryStore when an
    /// episode is cancelled or errors out: drop the queue, clear Now Playing.
    /// Clears Now Playing only when a stream was actually torn down, so a
    /// stop for an episode the player no longer holds (the user moved on
    /// to a file) leaves that file's Now Playing alone.
    func stopStreaming() {
        if teardownStreaming() { clearNowPlaying() }
    }

    /// Underrun / natural-end handler for the queue path. If the queue
    /// still has items, AVQueuePlayer auto-advanced and we keep playing.
    /// If it's empty and the episode is still rendering, buffer. If it's
    /// empty and the episode is done, finalize.
    private func handleQueueItemEnded(_ ended: AVPlayerItem, chunk: Int) {
        guard let qp = queuePlayer else { return }
        streamQueued.removeAll { $0.item === ended }
        // AVQueuePlayer removes the finished item from items() as it ends.
        let remaining = qp.items().count
        if remaining > 0 { return }   // still playing the next queued chunk
        currentTime = streamTimeline.start(ofChunk: chunk + 1)
        // Drained. Either we're ahead of the render-head (buffer) or the
        // whole episode is done (finalize). currentTime ~ renderHeadS means
        // we've consumed everything rendered so far.
        if streamDone {
            // The daemon confirmed completion (episode_complete → markStreamComplete)
            // and the queue has drained — episode finished. Gate on this measured
            // signal, NOT `currentTime >= episodeTotalS`: the estimate under-predicts
            // for a slow voice, which would finalize before the audio actually ends.
            // Selection hand-off to the canonical row is driven by HistoryStore on
            // episode_complete; here we just stop the queue.
            finalizeStreamingPlayback()
        } else {
            // Ran out of rendered audio ahead of completion — buffer.
            qp.pause()
            isPlaying = false
            isBuffering = true
            updateNowPlaying()
        }
    }

    /// Stop the queue at the end of a streaming episode without disturbing
    /// any subsequent AVAudioPlayer selection. Tears the queue path down.
    private func finalizeStreamingPlayback() {
        // "End of episode" is met: the live render played to its end.
        if sleepTimer == .endOfEpisode { setSleepTimer(nil) }
        teardownStreaming()
        clearNowPlaying()
    }

    /// Tear down the AVQueuePlayer sub-mode and reset its published state.
    /// Safe to call when not in stream mode (no-op). Returns true when a
    /// stream was torn down.
    @discardableResult
    private func teardownStreaming() -> Bool {
        guard queuePlayer != nil else { return false }
        if let obs = queueTimeObserver {
            queuePlayer?.removeTimeObserver(obs)
            queueTimeObserver = nil
        }
        if let obs = queueEndObserver {
            NotificationCenter.default.removeObserver(obs)
            queueEndObserver = nil
        }
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        StreamChunkLinks.release()
        streamQueued.removeAll()
        streamChunkURLs.removeAll()
        streamTimeline = StreamTimeline()
        streamChunksEnqueued = 0
        streamTotalChunks = 0
        streamStarted = false
        streamDone = false
        streamUserPaused = false
        renderHeadS = 0
        episodeTotalS = 0
        isBuffering = false
        isPlaying = false
        currentTime = 0
        duration = 0
        return true
    }

    /// Best-effort `voice-ctl stop` to kill any CLI-spawned mpv. Short-
    /// circuits unless an mpv answers on its IPC socket (the common case is
    /// none running). A stale socket file must not count: voice-ctl would
    /// fail on it, fall through to this app's own socket and send it `quit`,
    /// cancelling the very load that called this. Called from a background
    /// Task, so the subprocess wait never blocks the UI.
    nonisolated private static func killExternalMpv() {
        guard MpvCompatServer.isLive(MpvCompatServer.mpvSocketPath),
              let bin = ProcessRun.firstExecutable([
                  "\(NSHomeDirectory())/.local/bin/voice-ctl",
                  "/usr/local/bin/voice-ctl",
                  "/opt/homebrew/bin/voice-ctl",
              ]) else { return }
        _ = ProcessRun.run(bin, ["stop"])
    }

    // MARK: - Transport (play/pause/stop/seek/skip/speed)

    func togglePlay() {
        if let qp = queuePlayer {
            if isPlaying {
                qp.pause(); isPlaying = false; streamUserPaused = true
            } else {
                streamUserPaused = false
                // Don't fight an active buffering stall — there's nothing to
                // resume into until the next chunk lands (enqueueChunk resumes).
                if !isBuffering { qp.playImmediately(atRate: Float(playbackRate)); isPlaying = true; streamStarted = true }
            }
            updateNowPlaying()
            return
        }
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; flushProgress() }
        else { p.play(); isPlaying = true }
        updateNowPlaying()
    }

    func stop() {
        flushProgress()
        stopInternal(clearQueue: true)
    }

    private func stopInternal(clearQueue: Bool) {
        // The mpv-compat socket is only torn down on a real stop. Tearing it
        // down between tracks would leave hotkey → voice-ctl presses no-op
        // for the gap and the daemon couldn't route IPC during a queue
        // advance.
        if clearQueue { shutdownMpvServer() }
        // Tear down any streaming sub-mode on a real stop. teardownStreaming
        // resets renderHeadS/episodeTotalS/isBuffering and the queue itself.
        if clearQueue { teardownStreaming() }
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        activeEntry = nil
        // Cancel any in-flight load on a real stop. Without this, a load
        // task spawned by an earlier play() would land its MainActor.run
        // block (the loadingEntryID guard still matches), call p.play(),
        // and re-arm everything — audio resumes seconds after the user
        // hit "stop". The handoff `clearQueue: false` path keeps the
        // loadingEntryID intact so the in-flight load can complete.
        if clearQueue {
            loadingEntryID = nil
        }
        stopTick()
        clearNowPlaying()
    }

    func seek(toFraction f: Double) {
        if streamMode {
            // Denominator is the streaming total, not a loaded-file length.
            let total = episodeTotalS > 0 ? episodeTotalS : renderHeadS
            seek(toSeconds: total * f)
            return
        }
        guard let p = player, p.duration > 0 else { return }
        let target = max(0, min(p.duration, p.duration * f))
        p.currentTime = target
        currentTime = target
        updateNowPlaying()
    }

    /// Seek to `fraction` of `entry`: if it's already the active entry, seek in
    /// place; otherwise load it starting there (the load is async, so a timed
    /// seek after play() could land before the file was ready). One home for
    /// the row-scrubber + reader play-then-seek handoff.
    func playAndSeek(_ entry: VoiceEntry, toFraction fraction: Double) {
        if activeEntry?.id == entry.id {
            seek(toFraction: fraction)
        } else {
            play(entry, startFraction: fraction)
        }
    }

    func seek(toSeconds s: TimeInterval) {
        if let qp = queuePlayer {
            // `s` is in full-text space. The queue only holds the streamed
            // chunks (on a resume the draft prefix is concat'd server-side,
            // never enqueued), so the target is clamped to [base, render-head]
            // and found as a chunk plus an offset in it.
            guard let (chunk, offset) = streamTimeline.locate(s) else { return }
            let at = CMTime(seconds: offset, preferredTimescale: 600)
            if chunkIndex(of: qp.currentItem) == chunk {
                qp.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                requeueStream(from: chunk, at: at)
            }
            currentTime = streamTimeline.start(ofChunk: chunk) + offset
            updateNowPlaying()
            return
        }
        guard let p = player else { return }
        let target = max(0, min(p.duration, s))
        p.currentTime = target
        currentTime = target
        updateNowPlaying()
    }

    /// The chunk `item` plays, if it is one of ours.
    private func chunkIndex(of item: AVPlayerItem?) -> Int? {
        guard let item else { return nil }
        return streamQueued.first(where: { $0.item === item })?.chunk
    }

    /// Seek into a chunk other than the current one. A queue player can't go
    /// back to an item it has played (it left the queue), and a later item
    /// can't be made current without dropping the ones before it, so the
    /// queue is rebuilt from `chunk` with fresh items. Playback carries on if
    /// it was running, or was only waiting for a chunk the seek now has.
    private func requeueStream(from chunk: Int, at offset: CMTime) {
        guard let qp = queuePlayer, streamChunkURLs.indices.contains(chunk) else { return }
        let resume = isPlaying || (isBuffering && streamStarted && !streamUserPaused)
        qp.pause()
        qp.removeAllItems()
        streamQueued.removeAll()
        for i in chunk..<streamChunkURLs.count {
            let item = AVPlayerItem(url: streamChunkURLs[i])
            streamQueued.append((item, i))
            qp.insert(item, after: nil)
        }
        qp.seek(to: offset, toleranceBefore: .zero, toleranceAfter: .zero)
        if streamStarted { isBuffering = false }
        if resume {
            qp.playImmediately(atRate: Float(playbackRate))
            isPlaying = true
        }
    }

    func skip(by delta: TimeInterval) {
        if streamMode {
            seek(toSeconds: currentTime + delta)
            return
        }
        guard let p = player else { return }
        seek(toSeconds: p.currentTime + delta)
    }


    func bumpSpeed(_ direction: Int) {
        let stops = Self.speedStops
        let idx = stops.firstIndex(of: playbackRate) ?? stops.firstIndex(where: { $0 >= 1.0 }) ?? 2
        let next = max(0, min(stops.count - 1, idx + direction))
        playbackRate = stops[next]
    }

    func resetSpeed() { playbackRate = 1.0 }

    private func applyRate() {
        player?.rate = Float(playbackRate)
        // Stream path: setting rate on a playing AVQueuePlayer takes effect
        // immediately; while paused/buffering the resume sites re-apply it
        // (playImmediately(atRate:)). The read-along head + scrubber follow
        // for free — they are driven by currentTime, not wall clock.
        if let qp = queuePlayer, isPlaying { qp.rate = Float(playbackRate) }
    }

    // Tick — drives UI scrubber + Now Playing position + progress POST.

    // MARK: - Tick loop + progress persistence (POST /progress)

    private func startTick() {
        stopTick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                }
                self.advanceSleepTimer()
                self.updateNowPlaying()
                self.tickCounter += 1
                // Latch "listened" once playback crosses the threshold (≥90%),
                // so a row stays green / #completed in future sessions without
                // playing to the exact end — and only ONCE per entry per session
                //. Sent as completed=true; heartbeats omit completed so the
                // latch is never reset by a later partial replay.
                if self.isPlaying, let entry = self.activeEntry, self.duration > 0,
                   self.listenedMarkedFor != entry.ts,
                   p.currentTime / self.duration >= self.listenedThreshold {
                    self.listenedMarkedFor = entry.ts
                    self.postProgress(completed: true)
                }
                if self.isPlaying, self.tickCounter % self.progressPostEveryTicks == 0 {
                    self.postProgress()
                }
            }
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }


    /// Synchronous trigger; the network call itself is detached. Goes
    /// through DaemonClient so we get connection pooling + one timeout
    /// policy across all daemon endpoints.
    private func postProgress(started: Bool = false, completed: Bool? = nil, finalPlayedS: Double? = nil) {
        guard let entry = activeEntry else { return }
        let ts = entry.ts
        let played = finalPlayedS ?? currentTime
        let dur = duration > 0 ? duration : (entry.progress?.durationS ?? entry.durationS)
        Task.detached {
            do {
                _ = try await DaemonClient.shared.postProgress(
                    ts: ts, playedS: played,
                    durationS: dur > 0 ? dur : nil,
                    completed: completed, started: started
                )
            } catch {
                // Heartbeat, fires ~every 3 s — expected to drop while the
                // daemon restarts, so log-only (no user-facing banner).
                Log.player.debug("progress heartbeat dropped for \(ts, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Final flush — called on pause/stop/swap so the latest position
    /// always lands server-side before the player forgets its state.
    private func flushProgress() {
        guard activeEntry != nil, let p = player else { return }
        postProgress(finalPlayedS: p.currentTime)
    }

    // MPNowPlayingInfoCenter / MPRemoteCommandCenter.

    // MARK: - Now Playing / media keys (MPRemoteCommandCenter)

    private func bindRemoteCommands() {
        guard !nowPlayingBound else { return }
        nowPlayingBound = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true { self?.togglePlay() }
            }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        cc.skipBackwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -10) }
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: +10) }
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(toSeconds: event.positionTime) }
            return .success
        }
        // No nextTrackCommand: there is no play queue (single-entry playback
        // + streaming episodes), so advertising a next-track button would be
        // a control that does nothing.
    }

    private func updateNowPlaying(reset: Bool = false) {
        // Streaming sub-mode has no VoiceEntry yet — drive Now Playing from
        // the episode fields and use episodeTotalS as the duration.
        if streamMode {
            var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            if reset {
                info = [:]
                info[MPMediaItemPropertyTitle]  = streamTitle
                info[MPMediaItemPropertyArtist] = streamVoice
                info[MPMediaItemPropertyAlbumTitle] = "voice-say · \(streamBackend) (streaming)"
            }
            info[MPMediaItemPropertyPlaybackDuration] = episodeTotalS
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = (isPlaying && !isBuffering) ? playbackRate : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
            return
        }
        guard let entry = activeEntry else { return }
        var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if reset {
            info = [:]
            info[MPMediaItemPropertyTitle]  = entry.derivedTitle()
            info[MPMediaItemPropertyArtist] = entry.voice ?? "voice"
            info[MPMediaItemPropertyAlbumTitle] = "voice-say · \(entry.backend)"
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Held strongly (not as an ObjectIdentifier) so a replaced player
        // can't be freed and its address reused by the new one before the hop.
        nonisolated(unsafe) let finished = player
        Task { @MainActor in
            // Mark completed at exact duration so the UI shows ✓. Playback
            // state itself is left alone — the tick loop observes the
            // player's own stop and the UI settles from there (this matches
            // the behavior before the dead sequential-queue was removed).
            let action = Self.finishAction(isCurrentPlayer: finished === self.player,
                                           hasEntry: self.activeEntry != nil,
                                           sleepAtEndOfEpisode: self.sleepTimer == .endOfEpisode,
                                           successfully: flag)
            guard action != .ignore, let entry = self.activeEntry else { return }
            self.postProgress(completed: true, finalPlayedS: entry.durationS > 0 ? entry.durationS : self.duration)
            switch action {
            case .markAndSleep: self.setSleepTimer(nil)   // "end of episode": stop, don't advance
            case .markAndAdvance: self.onFinished?(entry)
            case .mark, .ignore: break
            }
        }
    }

    enum FinishAction: Equatable { case ignore, mark, markAndSleep, markAndAdvance }

    /// What a finish callback does. A player that is no longer the current
    /// one (the user started another entry before the main-actor hop)
    /// is ignored: acting on it would mark the NEW entry completed and
    /// advance from it.
    nonisolated static func finishAction(isCurrentPlayer: Bool, hasEntry: Bool,
                                         sleepAtEndOfEpisode: Bool,
                                         successfully: Bool) -> FinishAction {
        guard isCurrentPlayer, hasEntry else { return .ignore }
        if sleepAtEndOfEpisode { return .markAndSleep }
        return successfully ? .markAndAdvance : .mark
    }
}

// Shared playback accessors for a VoiceEntry — single source for the
// active/played/duration/progress math the inline PlayerPanel and the
// full-screen reader both need (was duplicated as private helpers in each).
// On AudioPlayer (Service→Model) rather than VoiceEntry so the model stays
// free of a player dependency.
@MainActor
extension AudioPlayer {
    func isActive(_ e: VoiceEntry) -> Bool { activeEntry?.id == e.id }

    func playedSeconds(of e: VoiceEntry) -> TimeInterval {
        isActive(e) ? currentTime : (e.progress?.playedS ?? 0)
    }

    /// Live duration while playing this entry, else its saved/best duration.
    func displayDuration(of e: VoiceEntry) -> Int {
        if isActive(e), duration > 0 { return Int(duration) }
        if let p = e.progress, p.durationS > 0 { return Int(p.durationS) }
        return Int(e.bestDurationS())
    }

    func progressFraction(of e: VoiceEntry) -> Double {
        if isActive(e), duration > 0 { return min(1, max(0, currentTime / duration)) }
        if let p = e.progress, p.durationS > 0 { return min(1, max(0, p.playedS / p.durationS)) }
        return 0
    }
}
