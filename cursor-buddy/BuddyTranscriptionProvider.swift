//
//  BuddyTranscriptionProvider.swift
//  cursor-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

enum BuddyTranscriptionProviderID: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case parakeet = "parakeet"
    case appleSpeech = "apple"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .parakeet:
            return "Parakeet"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic:
            return "Local-first"
        case .parakeet:
            return "Local Parakeet"
        case .appleSpeech:
            return "On-device Apple"
        }
    }
}

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var shouldStartAudioCaptureBeforeProviderReady: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

extension BuddyTranscriptionProvider {
    var shouldStartAudioCaptureBeforeProviderReady: Bool { true }
}

enum BuddyTranscriptionProviderFactory {
    struct ProviderSelection {
        let requestedProviderID: BuddyTranscriptionProviderID
        let displayedProviderID: BuddyTranscriptionProviderID
        let provider: any BuddyTranscriptionProvider
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let selection = resolveProviderSelection(preferredProvider: selectedProviderID())
        print("Transcription: using \(selection.provider.displayName)")
        return selection.provider
    }

    static func makeProvider(preferredProviderID: String) -> any BuddyTranscriptionProvider {
        let selection = resolveProviderSelection(
            preferredProvider: BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        )
        print("Transcription: using \(selection.provider.displayName)")
        return selection.provider
    }

    static func currentProviderSelection() -> ProviderSelection {
        resolveProviderSelection(preferredProvider: selectedProviderID())
    }

    static func providerSelection(preferredProviderID: String) -> ProviderSelection {
        resolveProviderSelection(
            preferredProvider: BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        )
    }

    static func providerIDsForSelectionGrid() -> [BuddyTranscriptionProviderID] {
        BuddyTranscriptionProviderID.allCases.filter { providerID in
            switch providerID {
            case .parakeet:
                return OpenClickyParakeetTranscriptionProvider().isConfigured
            default:
                return true
            }
        }
    }

    static func selectedProviderID() -> BuddyTranscriptionProviderID {
        let rawValue = UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
            ?? AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
            ?? BuddyTranscriptionProviderID.automatic.rawValue
        return BuddyTranscriptionProviderID(rawValue: rawValue.lowercased()) ?? .automatic
    }

    /// Local listening only: Parakeet when its model is installed, otherwise Apple Speech.
    /// Saved choices for removed cloud providers resolve the same way as Automatic.
    private static func resolveProviderSelection(preferredProvider: BuddyTranscriptionProviderID? = nil) -> ProviderSelection {
        let requested = preferredProvider ?? AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
            .flatMap { BuddyTranscriptionProviderID(rawValue: $0.lowercased()) } ?? .automatic
        if requested == .appleSpeech {
            return ProviderSelection(requestedProviderID: .appleSpeech, displayedProviderID: .appleSpeech,
                                     provider: AppleSpeechTranscriptionProvider())
        }
        let parakeetProvider = OpenClickyParakeetTranscriptionProvider()
        if parakeetProvider.isConfigured {
            return ProviderSelection(requestedProviderID: requested, displayedProviderID: .parakeet, provider: parakeetProvider)
        }
        return ProviderSelection(requestedProviderID: requested, displayedProviderID: .appleSpeech,
                                 provider: AppleSpeechTranscriptionProvider())
    }
}
