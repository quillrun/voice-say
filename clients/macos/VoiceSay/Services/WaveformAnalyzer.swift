import Foundation
import AVFoundation
import Accelerate

enum WaveformAnalyzer {
    /// `count`-bar RMS envelope of channel 0, normalized to the loudest bar.
    /// Streams the file in `chunkFrames`-frame reads and accumulates each bar's
    /// sum of squares, so memory stays at one chunk however long the file is
    /// (decoding a 1 h mp3 whole was ~635 MB of float PCM).
    static func envelope(url: URL, count: Int, chunkFrames: AVAudioFrameCount = 65_536) -> [Double]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let n = Int(file.length)
        let bars = max(1, count)
        guard n > 0, n >= bars,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
              let channel = buffer.floatChannelData else { return nil }

        // Same bucketing as a whole-file pass: `bucket` frames per bar, the
        // last bar takes the remainder.
        let bucket = n / bars
        var sumSq = [Double](repeating: 0, count: bars)
        var lens = [Int](repeating: 0, count: bars)
        var pos = 0
        while pos < n {
            guard (try? file.read(into: buffer, frameCount: chunkFrames)) != nil else { return nil }
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            var i = 0
            while i < got {
                let b = min((pos + i) / bucket, bars - 1)
                let barEnd = b == bars - 1 ? Int.max : (b + 1) * bucket
                let len = min(got - i, barEnd - (pos + i))
                var s: Float = 0
                vDSP_svesq(channel[0] + i, 1, &s, vDSP_Length(len))
                sumSq[b] += Double(s)
                lens[b] += len
                i += len
            }
            pos += got
        }

        var out = [Double](repeating: 0, count: bars)
        var peak = 0.0
        for b in 0..<bars where lens[b] > 0 {
            out[b] = (sumSq[b] / Double(lens[b])).squareRoot()
            peak = max(peak, out[b])
        }
        guard peak > 0 else { return nil }
        for i in out.indices { out[i] = max(0.12, min(1.0, pow(out[i] / peak, 0.6))) }
        return out
    }
}
