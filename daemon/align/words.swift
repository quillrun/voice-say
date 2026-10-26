// voice-say-words AUDIO [LOCALE]
//
// Word timings for the read-along (voice_say/align.py): transcribes AUDIO with
// macOS's on-device SpeechTranscriber and prints [[start_s, end_s, word], ...]
// as JSON. Nothing to install: the recognizer is part of macOS 26+, and its
// language asset is managed by the OS. Built by `make setup`.
import AVFoundation
import Foundation
import Speech

@main struct Words {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fail("usage: voice-say-words AUDIO [LOCALE]") }
        do {
            let words = try await transcribe(URL(fileURLWithPath: args[1]),
                                             locale: Locale(identifier: args.count > 2 ? args[2] : "en-US"))
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: words))
        } catch {
            fail("\(error)")
        }
    }

    static func transcribe(_ url: URL, locale: Locale) async throws -> [[Any]] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            fail("no on-device recognizer for \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var out: [[Any]] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    out.append([range.start.seconds, range.end.seconds,
                                String(result.text[run.range].characters)])
                }
            }
            return out
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collect.value
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
