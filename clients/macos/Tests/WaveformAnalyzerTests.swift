import Foundation
import AVFoundation
import Accelerate
import Testing
@testable import VoiceSay

@Suite("WaveformAnalyzer")
struct WaveformAnalyzerTests {

    private func writeTestWav() throws -> URL {
        let sr = 24000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-test-\(ProcessInfo.processInfo.globallyUniqueString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sr * 2)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        let half = Int(sr)
        for i in 0..<Int(frames) {
            ch[i] = i < half ? Float(0.5 * sin(2 * Double.pi * 220 * Double(i) / sr)) : 0
        }
        try file.write(from: buf)
        return url
    }

    @Test("envelope tracks loud vs silent passages")
    func tracksAmplitude() throws {
        let url = try writeTestWav()
        defer { try? FileManager.default.removeItem(at: url) }
        let env = try #require(WaveformAnalyzer.envelope(url: url, count: 96))
        #expect(env.count == 96)
        #expect(env.allSatisfy { $0 > 0 && $0 <= 1.0 })
        let loud = env[0..<40].reduce(0, +) / 40
        let quiet = env[56..<96].reduce(0, +) / 40
        #expect(loud > 0.5)
        #expect(quiet < 0.2)
    }

    /// Reference: the pre-chunking algorithm (whole file in memory,
    /// vDSP_rmsqv per bar). It loops reads because a single
    /// `read(into:)` can return short — the old code did one read and so
    /// silently bucketed a truncated file (119 808 of 120 000 frames here).
    private func wholeFileEnvelope(url: URL, count: Int) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var samples = [Float]()
        while file.framePosition < file.length {
            try file.read(into: chunk)
            samples.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0],
                                                           count: Int(chunk.frameLength)))
        }
        #expect(samples.count == Int(file.length))
        let n = samples.count, bucket = n / count
        var out = [Double](repeating: 0, count: count)
        for b in 0..<count {
            let start = b * bucket
            let len = (b == count - 1) ? (n - start) : bucket
            var rms: Float = 0
            samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + start, 1, &rms, vDSP_Length(len)) }
            out[b] = Double(rms)
        }
        let peak = out.max()!
        return out.map { max(0.12, min(1.0, pow($0 / peak, 0.6))) }
    }

    /// 5 s of 220 Hz sine under a slow amplitude sweep: 120 000 frames, so the
    /// default 64k chunk and a 1000-frame chunk both split bars across reads.
    @Test("chunked envelope matches the whole-file pass", arguments: [65_536, 1_000])
    func chunkedMatchesWholeFile(chunk: Int) throws {
        let sr = 24000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-sweep-\(ProcessInfo.processInfo.globallyUniqueString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = AVAudioFrameCount(sr * 5)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            ch[i] = Float((0.1 + 0.8 * abs(sin(t * 1.3))) * sin(2 * Double.pi * 220 * t))
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buf) }

        let expected = try wholeFileEnvelope(url: url, count: 96)
        let got = try #require(WaveformAnalyzer.envelope(url: url, count: 96,
                                                          chunkFrames: AVAudioFrameCount(chunk)))
        #expect(got.count == expected.count)
        let maxDiff = zip(got, expected).map { abs($0 - $1) }.max()!
        #expect(maxDiff < 1e-5)
    }

    @Test("nil for a missing file")
    func nilForMissing() {
        let url = URL(fileURLWithPath: "/nonexistent/\(ProcessInfo.processInfo.globallyUniqueString).wav")
        #expect(WaveformAnalyzer.envelope(url: url, count: 96) == nil)
    }
}
