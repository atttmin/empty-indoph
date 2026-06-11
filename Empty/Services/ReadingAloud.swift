//
//  ReadingAloud.swift
//  Empty
//

import AVFoundation
import Combine

/// macOS text-to-speech for the reader's aloud bar.
@MainActor
final class ReadingAloud: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var currentSnippet = ""

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String = "en-US") {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentSnippet = String(trimmed.prefix(48))
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func togglePause() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isSpeaking = false
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

extension ReadingAloud: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            isSpeaking = false
        }
    }
}