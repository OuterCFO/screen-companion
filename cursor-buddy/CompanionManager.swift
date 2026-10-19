//
//  CompanionManager.swift
//  cursor-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

@preconcurrency import AVFoundation
import OCComputerUseCore
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OCCore
import OCUI
import OCMarkdown
import OCMemory

enum CompanionVoiceState: String {
    case idle
    case listening
    case processing
    case responding
}

enum OpenClickyCompanionRuntimeMode {
    case menuBar
    case embeddedWindow
}

struct OpenClickyExternalProxyCursor: Identifiable {
    let id: UUID
    var screenLocation: CGPoint
    var caption: String?
    var accentHex: String?
}

struct OpenClickyPendingVisualGuidanceCalibrationAnchor {
    let overlayID: UUID
    let caption: String
    let predictedRect: CGRect
    let screenFrame: CGRect
    let screenshotWidthInPixels: Int?
    let screenshotHeightInPixels: Int?
    let displayNativeWidthInPixels: Int?
    let displayNativeHeightInPixels: Int?
    let createdAt: Date
}

@MainActor
final class CursorOverlayState: ObservableObject {
    // Actual rendered AI pointer position, not the system mouse position.
    var aiPointerScreenLocation: CGPoint?
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var currentAudioPowerLevel: CGFloat = 0
    @Published var detectedElementScreenLocation: CGPoint?
    @Published var detectedElementDisplayFrame: CGRect?
    @Published var detectedElementBubbleText: String?
    @Published var detectedElementReturnsImmediately: Bool = false
    @Published var replyPointerIsPinned = false
    @Published var replyHasVerifiedTarget = false
    @Published var agentTaskBubbleText: String?
    @Published var externalPrimaryCaptionText: String?
    @Published var externalPrimaryCaptionAccentHex: String?
    @Published var externalSecondaryCursors: [OpenClickyExternalProxyCursor] = []
    @Published var visualGuidanceOverlays: [OpenClickyVisualGuidanceOverlay] = []
    /// Live freehand trail while push-to-talk circle-select is active (AppKit screen coords).
    @Published var circleSelectLivePoints: [CGPoint] = []
    /// Intelligent snap rect locked after a completed circle (AppKit screen coords).
    @Published var circleSelectSnappedRect: CGRect?
    @Published var circleSelectSnapLabel: String?
    @Published var activeControlGlowRect: CGRect?
    @Published var activeControlGlowLabel: String?
}

enum ClickyAgentDockStatus: Equatable {
    case starting
    case running
    case done
    case failed
}

struct ClickyAgentDockItem: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID?
    var title: String
    /// Full, untruncated instruction the user gave the agent. Used by the
    /// conversation preview's YOU bubble so the user can see exactly what was
    /// requested (the short `title` is reserved for compact dock labels).
    var userInstruction: String
    var accentTheme: ClickyAccentTheme
    var status: ClickyAgentDockStatus
    var progressStageLabel: String
    var progressStepText: String?
    var activityStatusLines: [String]
    var caption: String?
    var suggestedNextActions: [String]
    var createdAt: Date
}

struct OpenClickyAppOpenRequest {
    let appName: String
    let instruction: String
}

struct OpenClickyAgentSelectionRequest {
    let agentName: String
    let followUpText: String?
    let instruction: String
}

struct OpenClickyNativeTypeRequest {
    let text: String
    let targetDescription: String
}

struct OpenClickyNativeKeyPressRequest {
    let key: String
    let modifiers: [String]
    let targetDescription: String
}

struct OpenClickyNativeClickRequest {
    let targetDescription: String
    let targetPhrase: String?
    let prefersLastPointedElement: Bool
}

struct OpenClickyFolderOpenRequest {
    let url: URL
    let displayName: String
    let instruction: String
}

struct OpenClickyWebOpenRequest {
    let url: URL
    let displayName: String
    let instruction: String
    let browserAppName: String?
}

struct OpenClickyReminderAddRequest {
    let title: String
    let instruction: String
}

struct OpenClickyReminderCountRequest {
    let instruction: String
}

struct OpenClickyMessagesSearchRequest {
    let personName: String
    let instruction: String
}

struct OpenClickyCompositeAppActionRequest {
    let appName: String
    let actionText: String
    let instruction: String
}

struct OpenClickyCompositeAppSearchActionRequest {
    let appName: String
    let query: String
    let instruction: String
}

struct OpenClickySpotifyPlaybackControlAction {
    enum Kind: String {
        case play
        case pause
        case playPause
        case next
        case previous
        case shuffleOn
        case shuffleOff
        case repeatOn
        case repeatOff
        case volumeUp
        case volumeDown
        case volumeMute
        case volumeSet
    }

    let kind: Kind
    let volumePercent: Int?

    var rawValue: String {
        if kind == .volumeSet, let volumePercent {
            return "\(kind.rawValue):\(volumePercent)"
        }
        return kind.rawValue
    }

    init(_ kind: Kind, volumePercent: Int? = nil) {
        self.kind = kind
        self.volumePercent = volumePercent
    }
}

struct OpenClickySystemVolumeControlAction {
    enum Kind: String {
        case volumeUp
        case volumeDown
        case mute
        case setVolume
    }

    let kind: Kind
    let volumePercent: Int?

    var rawValue: String {
        if kind == .setVolume, let volumePercent {
            return "\(kind.rawValue):\(volumePercent)"
        }
        return kind.rawValue
    }

    init(_ kind: Kind, volumePercent: Int? = nil) {
        self.kind = kind
        self.volumePercent = volumePercent
    }
}

enum OpenClickyComputerUsePointingResolver: String {
    case anthropicAPI = "anthropic_api"
    case codexCLI = "codex_cli"
    case openAIResponses = "openai_responses"
    case unsupported = "unsupported"
}

nonisolated struct OpenClickyLocalAutomationResult: Sendable {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32
}

struct OpenClickyRequestTiming {
    let requestID: String
    let source: String
    let text: String
    let requestedAt: Date
}

// M1: previously this was `@unchecked Sendable` with an unsynchronised `var
// didComplete` — safe only because all access happened to land on the main
// actor, with nothing enforcing that. Now the flag is guarded by an
// OSAllocatedUnfairLock so the invariant holds regardless of caller context.
final class OpenClickyRequestCompletionState: @unchecked Sendable {
    private let didCompleteStorage = OSAllocatedUnfairLock(initialState: false)
    var didComplete: Bool {
        get { didCompleteStorage.withLock { $0 } }
        set { didCompleteStorage.withLock { $0 = newValue } }
    }
}

nonisolated enum OpenClickyLocalAutomationRunner {
    static func runAppleScript(_ script: String) -> OpenClickyLocalAutomationResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-ss", "-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return OpenClickyLocalAutomationResult(
                output: "",
                errorOutput: error.localizedDescription,
                terminationStatus: -1
            )
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return OpenClickyLocalAutomationResult(
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            terminationStatus: process.terminationStatus
        )
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

nonisolated enum OpenClickySystemOutputVolume {
    static func currentScalar() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        if let master = scalar(for: deviceID, element: kAudioObjectPropertyElementMain) {
            return master
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { scalar(for: deviceID, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    @discardableResult
    static func setScalar(_ scalar: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let clampedScalar = min(max(scalar, 0), 1)
        if setScalar(clampedScalar, for: deviceID, element: kAudioObjectPropertyElementMain) {
            return true
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
        return channels
            .map { setScalar(clampedScalar, for: deviceID, element: $0) }
            .contains(true)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func scalar(for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == 0 else { return nil }
        return Float(value)
    }

    private static func setScalar(
        _ scalar: Float,
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == 0,
              settable.boolValue else {
            return false
        }

        var value = Float32(scalar)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == 0
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    let cursorOverlayState = CursorOverlayState()
    @Published var voiceState: CompanionVoiceState = .idle {
        didSet {
            cursorOverlayState.voiceState = voiceState
            if voiceState == .idle, oldValue != .idle {
                scheduleVoiceResponseCaptionClear(after: 1.2)
            }
            // Cancel any existing watchdog and reschedule when entering
            // .processing — any subsequent state change cancels it.
            processingWatchdogTask?.cancel()
            processingWatchdogTask = nil
            if voiceState == .processing {
                processingWatchdogTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.processingWatchdogTimeout * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.recoverFromStuckProcessingStateIfNeeded()
                }
            }
        }
    }
    @Published var lastTranscript: String?
    var currentAudioPowerLevel: CGFloat = 0 {
        didSet {
            cursorOverlayState.currentAudioPowerLevel = currentAudioPowerLevel
        }
    }
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasFullDiskAccessPermission = false
    @Published var hasSystemEventsAutomationPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    var detectedElementScreenLocation: CGPoint? {
        didSet {
            updateCursorOverlayState { [detectedElementScreenLocation] overlayState in
                overlayState.detectedElementScreenLocation = detectedElementScreenLocation
            }
        }
    }
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    var detectedElementDisplayFrame: CGRect? {
        didSet {
            updateCursorOverlayState { [detectedElementDisplayFrame] overlayState in
                overlayState.detectedElementDisplayFrame = detectedElementDisplayFrame
            }
        }
    }
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    var detectedElementBubbleText: String? {
        didSet {
            updateCursorOverlayState { [detectedElementBubbleText] overlayState in
                overlayState.detectedElementBubbleText = detectedElementBubbleText
            }
        }
    }
    /// True for task-start handoff flights that should tag the corner briefly
    /// and come straight back instead of holding a pointing caption.
    var detectedElementReturnsImmediately: Bool = false {
        didSet {
            updateCursorOverlayState { [detectedElementReturnsImmediately] overlayState in
                overlayState.detectedElementReturnsImmediately = detectedElementReturnsImmediately
            }
        }
    }
    var lastPointedElementScreenLocation: CGPoint?
    var lastPointedElementDisplayFrame: CGRect?
    var lastPointedElementLabel: String?
    var lastPointedElementAt: Date?

    private func updateCursorOverlayState(_ apply: @escaping @MainActor (CursorOverlayState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self.cursorOverlayState)
        }
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    var onboardingVideoEndObserver: NSObjectProtocol?
    var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let compactInputWindowManager = CompactInputWindowManager()
    let agentDockWindowManager = ClickyAgentDockWindowManager()
    let agentMenuBarStatusManager = AgentMenuBarStatusManager()
    let settingsWindowManager = OpenClickySettingsWindowManager()
    let logViewerWindowManager = OpenClickyLogViewerWindowManager()
    let markdownViewerWindowManager = OpenClickyMarkdownViewerWindowManager()
    let codexHomeManager = CodexHomeManager()
    let nativeComputerUseController = OpenClickyNativeComputerUseController()
    let backgroundComputerUseController = OpenClickyBackgroundComputerUseController()
    @Published var codexAgentSessions: [CodexAgentSession]
    @Published var activeCodexAgentSessionID: UUID
    /// Session IDs the user has archived from the chat sidebar. Persisted to UserDefaults.
    /// Archived sessions remain in `codexAgentSessions` so transcripts/state are preserved;
    /// the sidebar simply hides them under an Archived section.
    @Published var archivedSessionIDs: Set<UUID> = ChatWorkspaceArchiveStore.load()
    let codexHUDWindowManager = CodexHUDWindowManager()
    let wikiViewerPanelManager = WikiViewerPanelManager()
    @Published private(set) var bundledKnowledgeIndex = OCCore.WikiManager.Index.empty
    @Published var latestVoiceResponseCard: ClickyResponseCard?
    @Published var homeChatEntries: [CodexTranscriptEntry] = CompanionManager.loadTutorChatEntries()
    @Published var isHomeChatModeActive = false
    @Published var handoffQueue: [HandoffQueuedRegionScreenshot] = []
    /// Sealed circle-while-talking stroke from the most recent PTT hold, awaiting voice/agent attach.
    var pendingCircleSelectStroke: CircleSelectSealedStroke?
    /// Crop capture started at PTT release so the final transcript can attach without extra latency.
    var pendingCircleSelectCaptureTask: Task<HandoffQueuedRegionScreenshot?, Never>?
    /// A sealed circle belongs to one just-finished voice hold. It must not
    /// survive indefinitely and become context for a later, unrelated task.
    var pendingCircleSelectExpiryTask: Task<Void, Never>?
    /// Live partial transcript while PTT is held — used to bias circle snap to spoken items.
    var circleSelectLivePartialTranscript: String = ""
    let circleSelectSession = CircleSelectSession()
    @Published var agentDockItems: [ClickyAgentDockItem] = []
    /// Cursor-following speech bubble with Apple/Codex/Claude selector chips.
    /// Caption text still mirrors onto the full-screen cursor overlay when
    /// voice-response captions are enabled; this panel is the interactive path.
    let responseOverlayManager = CompanionResponseOverlayManager()
    var companionConversations = CompanionConversationStore.load(
        legacyEntries: CompanionManager.loadTutorChatEntries(),
        summary: UserDefaults.standard.string(forKey: "openClickyCompactedVoiceConversationArchive"))
    var tutorDockItemID: UUID { companionConversations.activeID }

    /// Anthropic API key for direct Claude requests.
    /// Environment fallback supports Xcode schemes and local launch scripts.
    private static let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey()
    private static let openAIAPIKey = AppBundleConfiguration.openAIAPIKey()
    static let tutorModeDefaultsKey = "isTutorModeEnabled"

    private static func initialTutorModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: tutorModeDefaultsKey) as? Bool ?? false
    }

    lazy var claudeAPI: ClaudeAPI = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return ClaudeAPI(
            apiKey: Self.anthropicAPIKey,
            model: modelOption.id,
            maxOutputTokens: modelOption.maxOutputTokens
        )
    }()

    lazy var openAIAPI: OpenAIAPI = {
        let modelOption = OpenClickyModelCatalog.voiceAnalysisModel(withID: selectedModel)
        return OpenAIAPI(
            apiKey: Self.openAIAPIKey,
            model: modelOption.id,
            maxOutputTokens: modelOption.maxOutputTokens
        )
    }()

    /// Every text answer goes through these provider chains; see `AnswerProviders.swift`.
    lazy var answerProviders: AnswerProviderRegistry = .standard(
        claudeCode: { [unowned self] in self.claudeCodeCLI },
        anthropicAPI: { [unowned self] in self.claudeAPI },
        codex: { [unowned self] in self.codexVoiceSession },
        openAIAPI: { [unowned self] in self.openAIAPI })

    lazy var claudeCodeCLI: ClaudeCodeCLIClient? = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return ClaudeCodeCLIClient(model: modelOption.id, maxOutputTokens: modelOption.maxOutputTokens)
    }()

    lazy var codexVoiceSession: CodexVoiceSession = {
        let modelOption = OpenClickyModelCatalog.codexVoiceSessionModel(withID: selectedModel)
        return CodexVoiceSession(model: modelOption.id, homeManager: codexHomeManager)
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private static func loadTutorChatEntries() -> [CodexTranscriptEntry] {
        if let data = UserDefaults.standard.data(forKey: CompanionConversationStore.defaultsKey),
           let store = try? JSONDecoder().decode(CompanionConversationStore.self, from: data),
           let current = store.conversations.first(where: { $0.id == store.activeID && !$0.archived }) { return current.entries }
        guard let data = UserDefaults.standard.data(forKey: "openclicky.tutorChatHistory"),
              let entries = try? JSONDecoder().decode([CodexTranscriptEntry].self, from: data) else { return [] }
        var uniqueEntries: [CodexTranscriptEntry] = []
        for entry in entries {
            if let last = uniqueEntries.last, last.role == entry.role, last.text == entry.text { continue }
            uniqueEntries.append(entry)
        }
        return Array(uniqueEntries.suffix(24))
    }

    private static func restoredTutorExchanges() -> [(userTranscript: String, assistantResponse: String)] {
        var exchanges: [(userTranscript: String, assistantResponse: String)] = []
        var prompt: String?
        for entry in loadTutorChatEntries() {
            if entry.role == .user { prompt = entry.text }
            if entry.role == .assistant, let user = prompt {
                exchanges.append((userTranscript: user, assistantResponse: entry.text))
                prompt = nil
            }
        }
        return exchanges
    }

    var conversationHistory: [(userTranscript: String, assistantResponse: String)] = CompanionManager.restoredTutorExchanges()
    var compactedVoiceConversationArchive: String?
    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?
    var currentResponseTaskToken: UUID?

    var currentVoiceResponseRequestID: String?
    var currentVoiceResponseCompletionToken: UUID?
    var currentVoiceResponseCancellationHandler: ((String) -> Void)?
    // System-voice fallback removed. We never speak through
    // AVSpeechSynthesizer — failures stay silent and surface only in
    // the response card and logs.
    var pendingAgentVoiceFollowUpSessionID: UUID?
    var pendingAgentVoiceFollowUpCreatedAt: Date?
    var pendingAgentVoiceFollowUpSource: String?
    /// Set when Haiku's last response offered to spin up an agent
    /// ("want me to spin up an agent to X?"). On the next transcript,
    /// a confirmation ("yes", "okay then", "sure") spawns an agent with
    /// this instruction. Without this glue Haiku's offer dead-ended —
    /// the harness only spawns when the transcript itself says "agent".
    var pendingAgentOfferInstruction: String?
    var pendingAgentOfferAt: Date?
    var deferredLiveAgentRoutePartial: String?
    var deferredLiveAgentRoutePartialAt: Date?
    /// Most recent user prompt in the shared instant/voice conversation.
    /// This lets a later referential agent request ("on it", "do that")
    /// resolve to what the user was just talking about, regardless of
    /// whether the prior turn came from push-to-talk, Realtime voice, or
    /// the panel's instant text entry.
    var lastVoiceUserTranscript: String?
    var lastVoiceUserTranscriptAt: Date?
    var previousVoiceUserTranscript: String?
    var previousVoiceUserTranscriptAt: Date?
    static let pendingAgentVoiceFollowUpTTL: TimeInterval = 90
    static let pendingAgentOfferTTL: TimeInterval = 90
    static let deferredLiveAgentRoutePartialTTL: TimeInterval = 20

    /// Guards against a single voice utterance launching the same agent
    /// task twice when overlapping routes both resolve to an agent start.
    var lastVoiceAgentStartFingerprint: String?
    var lastVoiceAgentStartAt: Date?
    var lastVoiceAgentStartSessionID: UUID?
    var suppressNextVoiceAgentStartAcknowledgement = false
    static let voiceAgentStartDuplicateTTL: TimeInterval = 8

    /// Guards against the realtime final-transcript callback and the
    /// realtime tool-route callback both firing for the same utterance,
    /// producing two near-identical requests ~1s apart.

    // MARK: Speculative pre-fire state
    //
    // While the user is still talking, Deepgram emits interim
    // transcripts every ~200ms. When a partial is "stable" (unchanged
    // for ~1.5s) and looks like a pure question with no screen
    // dependency, we kick off a speculative Claude call against that
    // partial. Tokens stream into `speculativeBufferedDelta` but DO NOT
    // play yet — we wait for the user to release the key. If the final
    // transcript matches the partial we fired against, we commit the
    // buffered tokens straight into the TTS pipeline (instant audio).
    // If the final diverges, we cancel and fall through to the normal
    // path. All speculative work runs on its own Task — this never
    // blocks the main actor's cursor tracking, audio capture, or any
    // in-flight Cartesia/ElevenLabs playback.

    /// Whether speculative pre-fire is enabled (Settings → Voice).
    var voiceResponseCaptionsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppBundleConfiguration.userVoiceResponseCaptionsEnabledDefaultsKey) as? Bool ?? false
    }

    /// Counter to prevent runaway re-fires when the user keeps
    /// extending a partial across many stability windows.
    /// Last-seen partial text + arrival time, used to detect stability.
    /// Scheduled re-evaluation of stability after the dwell window.
    var lastAgentContextSessionID: UUID?
    var announcedAgentFileURLs: Set<String> = []
    var pendingSystemAnnouncementTask: Task<Void, Never>?
    var pendingSystemAnnouncementSessionID: UUID?
    var speakingSystemAnnouncementSessionID: UUID?
    var silencedAgentSpeechSessionIDs: Set<UUID> = []
    var liveHandledComputerUseFingerprints: Set<String> = []
    var lastAgentProgressNarrationAt: Date?
    /// The phrase last spoken for each running agent session, keyed by
    /// session ID. Used to suppress duplicate progress narrations — we
    /// only speak when the *content* of the activity changed, never just
    /// because a polling tick fired.
    var lastAgentProgressNarrationSignatures: [UUID: String] = [:]
    static let agentProgressVoiceUpdatesDefaultsKey = "agentProgressVoiceUpdatesEnabled"
    var currentFolderContextURL: URL?
    var activeRequestTiming: OpenClickyRequestTiming?
    var agentRequestTimingsBySessionID: [UUID: OpenClickyRequestTiming] = [:]
    var agentExecutionStartDatesBySessionID: [UUID: Date] = [:]
    /// Agent tasks started since launch; only their results are shown by the pointer, not restored older tasks.
    var agentSessionsStartedThisLaunch = Set<UUID>()
    /// Sessions whose terminal outcome (success, failure, cancellation) has
    /// already been narrated — so we don't re-announce on every Combine republish.
    /// Stores outcome labels like "success", "failed", "cancelled".
    var lastNarratedAgentOutcomeBySessionID: [UUID: String] = [:]

    private var processingWatchdogTask: Task<Void, Never>?
    static let processingWatchdogTimeout: TimeInterval = 30

    private var shortcutTransitionCancellable: AnyCancellable?
    private var compactChordCancellable: AnyCancellable?
    /// The app the user was in when they pressed Fn + Command; written text is pasted back into it.
    var writeTargetApplication: NSRunningApplication?
    private var shiftDoubleTapCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    var externalControlBridgeServer: OpenClickyExternalControlBridgeServer?
    var externalProxyClearTask: Task<Void, Never>?
    var agentTaskBubbleClearTask: Task<Void, Never>?
    var externalPrimaryCursorMoveTask: Task<Void, Never>?
    var externalSecondaryCursorClearTasks: [UUID: Task<Void, Never>] = [:]
    var visualGuidanceOverlayClearTasks: [UUID: Task<Void, Never>] = [:]
    var pendingVisualGuidanceCalibrationAnchor: OpenClickyPendingVisualGuidanceCalibrationAnchor?
    var activeControlGlowClearTask: Task<Void, Never>?
    var agentStatusCancellables: [UUID: AnyCancellable] = [:]
    var agentActivityCancellables: [UUID: AnyCancellable] = [:]
    var agentLoopActivityCancellables: [UUID: AnyCancellable] = [:]
    var agentProgressStageCancellables: [UUID: AnyCancellable] = [:]
    var agentTitleCancellables: [UUID: AnyCancellable] = [:]
    var pendingAgentActivityRefreshTasks: [UUID: Task<Void, Never>] = [:]
    var pendingRelaunchableSnapshotPersistTask: Task<Void, Never>?
    var pendingRelaunchableAgentResumeTask: Task<Void, Never>?
    var relaunchableAgentResumeTimer: Timer?
    var autoResumedRelaunchSessionIDs: Set<UUID> = []
    var tutorIdleCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    var pendingAgentDockItemRemovalTasks: [UUID: DispatchWorkItem] = [:]

    /// Screenshot captured in parallel with audio recording. Started the
    /// instant push-to-talk is pressed so capture latency overlaps with
    /// the user actually speaking instead of running serially after the
    /// final transcript arrives. Consumed by the voice response path and
    /// reset after every request.
    var prewarmedScreenshotTask: Task<[CompanionScreenCapture], Error>?
    var prewarmedScreenshotStartedAt: Date?
    /// Maximum age before a prewarmed screenshot is considered stale.
    /// Push-to-talk plus model latency rarely exceeds this; if it does,
    /// we fall back to a fresh capture so the AI sees current screen state.
    static let prewarmedScreenshotMaxAge: TimeInterval = 8.0
    /// Duration to keep a cancelled dock item visible so users can see
    /// explicit completion text before it auto-dismisses.
    let cancelledDockItemHoldDuration: TimeInterval = 0.45
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    var transientHideTask: Task<Void, Never>?
    var voiceFollowUpStopTask: Task<Void, Never>?

    /// True when the base OpenClicky experience is ready. Camera access is
    /// deliberately excluded because Visual Intelligence and meeting notes are
    /// opt-in features, not prerequisites for voice, screen, or Agent Mode.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    var permissionSnapshot: PermissionSnapshot {
        PermissionSnapshot(
            accessibility: hasAccessibilityPermission ? .granted : .missing,
            screenRecording: hasScreenRecordingPermission ? .granted : .missing,
            microphone: hasMicrophonePermission ? .granted : .missing,
            screenContent: hasScreenContentPermission ? .granted : .missing
        )
    }

    var permissionGuideViewState: PermissionGuideAssistant.ViewState {
        PermissionGuideAssistant.viewState(
            for: permissionSnapshot,
            entryContext: hasCompletedOnboarding ? .returningUser : .onboarding
        )
    }

    var latestResponseCard: ClickyResponseCard? {
        codexAgentSession.latestResponseCard ?? latestVoiceResponseCard
    }

    var codexAgentSession: CodexAgentSession {
        codexAgentSessions.first { $0.id == activeCodexAgentSessionID }
            ?? codexAgentSessions.first
            ?? CodexAgentSession(title: "Ask Agent", accentTheme: .current)
    }

    private static func restoredArchivedSessions(from archivedSessionIDs: Set<UUID>) -> [CodexAgentSession] {
        ChatWorkspaceArchiveStore.loadSnapshots().compactMap { snapshot in
            guard archivedSessionIDs.contains(snapshot.id) else { return nil }
            let accentTheme = ClickyAccentTheme.current // One pointer color everywhere.
            let session = CodexAgentSession(id: snapshot.id, title: snapshot.title, accentTheme: accentTheme)
            session.restoreArchivedState(
                entries: snapshot.entries,
                activeThreadID: snapshot.activeThreadID,
                lastSubmittedPrompt: snapshot.lastSubmittedPrompt
            )
            return session
        }
    }

    private static func restoredInterruptedSessions(archivedSessionIDs: Set<UUID>) -> [CodexAgentSession] {
        ChatWorkspaceArchiveStore.loadRelaunchableSnapshots().compactMap { snapshot in
            guard !archivedSessionIDs.contains(snapshot.id) else { return nil }
            let accentTheme = ClickyAccentTheme.current // One pointer color everywhere.
            let session = CodexAgentSession(id: snapshot.id, title: snapshot.title, accentTheme: accentTheme)
            session.restoreInterruptedRelaunchState(
                entries: snapshot.entries,
                activeThreadID: snapshot.activeThreadID,
                lastSubmittedPrompt: snapshot.lastSubmittedPrompt,
                canResume: snapshot.wasRelaunchResumeCandidate ?? false
            )
            return session
        }
    }

    private static func restoredInterruptedDockItems(from sessions: [CodexAgentSession]) -> [ClickyAgentDockItem] {
        sessions.map { session in
            let prompt = session.lastSubmittedPromptText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resumeCaption = session.canResumeAfterRelaunch
                ? "Open to resume this task after relaunch."
                : "Restored after relaunch."
            return ClickyAgentDockItem(
                id: session.id,
                sessionID: session.id,
                title: session.title,
                userInstruction: prompt?.isEmpty == false ? (prompt ?? session.title) : session.title,
                accentTheme: session.accentTheme,
                status: .failed,
                progressStageLabel: session.canResumeAfterRelaunch ? "Interrupted" : session.progressStage.label,
                progressStepText: session.latestActivityDisplaySummary ?? session.latestActivitySummary ?? resumeCaption,
                activityStatusLines: session.activityStatusLines.isEmpty ? [resumeCaption] : session.activityStatusLines,
                caption: session.latestActivityDisplaySummary ?? session.latestActivitySummary ?? resumeCaption,
                suggestedNextActions: session.latestResponseCard?.suggestedNextActions ?? [],
                createdAt: session.createdAt
            )
        }
    }

    let runtimeMode: OpenClickyCompanionRuntimeMode

    init(runtimeMode: OpenClickyCompanionRuntimeMode = .menuBar) {
        self.runtimeMode = runtimeMode
        let restoredVoiceArchive = UserDefaults.standard
            .string(forKey: Self.compactedVoiceConversationArchiveDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let restoredVoiceArchive, !restoredVoiceArchive.isEmpty {
            compactedVoiceConversationArchive = restoredVoiceArchive
        }

        let initialAgentSession = CodexAgentSession(title: "Ask Agent", accentTheme: .current)
        let restoredArchiveIDs = ChatWorkspaceArchiveStore.load()
        archivedSessionIDs = restoredArchiveIDs
        let restoredArchivedSessions = Self.restoredArchivedSessions(from: restoredArchiveIDs)
        let restoredInterruptedSessions = Self.restoredInterruptedSessions(archivedSessionIDs: restoredArchiveIDs)
        codexAgentSessions = restoredInterruptedSessions + [initialAgentSession] + restoredArchivedSessions
        agentDockItems = Self.restoredInterruptedDockItems(from: restoredInterruptedSessions)
        activeCodexAgentSessionID = restoredInterruptedSessions.first?.id ?? initialAgentSession.id
        OpenClickyMessageLogStore.shared.append(
            lane: "system",
            direction: "outgoing",
            event: "openclicky.runtime.started",
            fields: [
                "nativeCUARouterVersion": "direct-cua-explicit-agent-v4",
                "agentAssignment": "explicit-only",
                "computerUseBackend": selectedComputerUseBackendID,
                "restoredInterruptedAgentTasks": restoredInterruptedSessions.count,
                "restoredInterruptedDockItems": agentDockItems.count
            ]
        )
        // Bind the automation scheduler so cron / interval prompts can fire
        // through this CompanionManager while the app is running.
        OpenClickyAutomationStore.shared.bind(companion: self)
        // Seed bundled built-in specialist agents on first launch.
        OpenClickyAgentStore.shared.seedBuiltinsFromBundleIfNeeded()
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible: Bool = false

    /// The model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = CompanionManager.initialVoiceResponseModelID()
    @Published var selectedComputerUseModel: String = OpenClickyModelCatalog.computerUseModel(
        withID: UserDefaults.standard.string(forKey: "selectedComputerUseModel") ?? OpenClickyModelCatalog.defaultComputerUseModelID
    ).id
    @Published var selectedComputerUseBackendID: String = OpenClickyComputerUseBackendID.resolving(
        UserDefaults.standard.string(forKey: AppBundleConfiguration.userComputerUseBackendDefaultsKey)
    ).rawValue
    @Published var isTutorModeEnabled: Bool = CompanionManager.initialTutorModeEnabled()
    /// Advanced-mode concept retired — the visible "Ask Agent" panel and the
    /// settings toggle were removed. Hard-coded true so dependent code paths
    /// (agent dashboard, memory icon, computer-use entry points) keep working
    /// for everyone, including users who previously had the toggle off.
    @Published var isAdvancedModeEnabled: Bool = true

    /// Where the agent dock parks itself on the active screen. Persisted
    /// to UserDefaults; defaults to `.topRight`.
    @Published var agentParkingPosition: AgentParkingPosition = {
        if let raw = UserDefaults.standard.string(forKey: AgentParkingPosition.userDefaultsKey),
           let parsed = AgentParkingPosition(rawValue: raw) {
            return parsed
        }
        return .default
    }()

    let userActivityIdleDetector = UserActivityIdleDetector()
    let tutorTargetClickTracker = TutorTargetClickTracker()
    var isTutorObservationInFlight = false
    var lastVoiceInteractionCompletedAt: Date = .distantPast
    var agentDockFollowTimer: Timer?

    /// User preference for whether the OpenClicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    @Published var isActivationShortcutEnabled: Bool = true
    func start() {
        loadBundledKnowledgeIndex()
        refreshAllPermissions()
        // Warm ScreenCaptureKit's window enumeration so the first
        // screenshot after a key press doesn't pay the cold-start tax.
        CompanionScreenCaptureUtility.prewarmShareableContent()
        print("OpenClicky runtime identity - bundleID: \(Bundle.main.bundleIdentifier ?? "unknown"), appPath: \(Bundle.main.bundleURL.path)")
        print("OpenClicky start - accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), fullDiskAccess: \(hasFullDiskAccessPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindAgentSessionObservation()
        if runtimeMode == .menuBar { refreshCompanionTaskIcons() }
        startRelaunchableAgentAutoResumeChecks()
        if runtimeMode == .menuBar, !agentDockItems.isEmpty {
            showAgentDockWindowNearCurrentScreen()
        }
        startExternalControlBridgeIfNeeded()
        if runtimeMode == .menuBar && isTutorModeEnabled {
            startTutorIdleObservation()
        }
        answerProviders.warmUp(for: OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel),
                               systemPrompt: currentVoiceResponseSystemPrompt())

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && isClickyCursorEnabled {
            showCursorOverlayIfAvailable()
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Completes the old onboarding entry path and shows the cursor without
    /// any welcome, video, or demo sequence.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        if runtimeMode == .menuBar {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Onboarding replay is disabled. Keep this as a no-op for old call sites.
    func replayOnboarding() {
        tearDownOnboardingVideo()
        stopOnboardingMusic()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementReturnsImmediately = false
    }

    func rememberPointedElement(at point: CGPoint, displayFrame: CGRect?, label: String?) {
        lastPointedElementScreenLocation = point
        lastPointedElementDisplayFrame = displayFrame
        lastPointedElementLabel = label
        lastPointedElementAt = Date()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        cancelCircleSelectSession()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskToken = nil
        claudeCodeCLI?.stop()
        codexVoiceSession.stop()
        codexAgentSessions.forEach { $0.stop(reason: "companion_stop") }
        // M11: tear down the Background Computer Use runtime too. Previously
        // stop() killed the external bridge, voice, and timers but never the
        // spawned BCU helper, orphaning it across app restarts.
        backgroundComputerUseController.stopRuntime()
        externalControlBridgeServer?.stop()
        externalControlBridgeServer = nil
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = nil
        cursorOverlayState.agentTaskBubbleText = nil
        externalPrimaryCursorMoveTask?.cancel()
        externalPrimaryCursorMoveTask = nil
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        pendingAgentActivityRefreshTasks.values.forEach { $0.cancel() }
        pendingAgentActivityRefreshTasks.removeAll()
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = nil
        pendingRelaunchableAgentResumeTask?.cancel()
        pendingRelaunchableAgentResumeTask = nil
        relaunchableAgentResumeTimer?.invalidate()
        relaunchableAgentResumeTimer = nil
        autoResumedRelaunchSessionIDs.removeAll()
        pendingAgentDockItemRemovalTasks.values.forEach { $0.cancel() }
        pendingAgentDockItemRemovalTasks.removeAll()
        agentStatusCancellables.removeAll()
        agentActivityCancellables.removeAll()
        agentLoopActivityCancellables.removeAll()
        agentProgressStageCancellables.removeAll()
        agentTitleCancellables.removeAll()
        shortcutTransitionCancellable?.cancel()
        compactChordCancellable?.cancel()
        shiftDoubleTapCancellable?.cancel()
        escapeKeyCancellable?.cancel()
        stopTutorIdleObservation()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadFullDiskAccess = hasFullDiskAccessPermission
        let previouslyHadSystemEventsAutomation = hasSystemEventsAutomationPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Screen content permission is persisted after the ScreenCaptureKit
        // picker approves it, but it is only useful when real Screen Recording
        // permission is also present.
        let persistedScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        hasScreenContentPermission = hasScreenRecordingPermission && persistedScreenContentPermission
        hasFullDiskAccessPermission = OpenClickyMacPrivacyPermissionProbe.hasLikelyFullDiskAccess()
        hasSystemEventsAutomationPermission = OpenClickyMacPrivacyPermissionProbe.hasSystemEventsAutomationPermission(prompt: false)

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadFullDiskAccess != hasFullDiskAccessPermission
            || previouslyHadSystemEventsAutomation != hasSystemEventsAutomationPermission {
            print("Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), fullDiskAccess: \(hasFullDiskAccessPermission), systemEventsAutomation: \(hasSystemEventsAutomationPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadFullDiskAccess && hasFullDiskAccessPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "full_disk_access")
        }
        if !previouslyHadSystemEventsAutomation && hasSystemEventsAutomationPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "system_events_automation")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }

    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("Screen content capture result - width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && !isOverlayVisible && isClickyCursorEnabled {
                        showCursorOverlayIfAvailable()
                    }
                }
            } catch {
                print("Screen content permission request failed: \(error)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    hasScreenContentPermission = false
                    UserDefaults.standard.set(false, forKey: "hasScreenContentPermission")
                }
            }
        }
    }

    // MARK: - Private

    func loadBundledKnowledgeIndex() {
        let memoriesDirectory = codexHomeManager.memoriesDirectory
        let learnedSkillsDirectory = codexHomeManager.learnedSkillsDirectory

        Task.detached(priority: .utility) {
            let bundledIndex = OCCore.WikiManager.Index.loadForAppBundle()
            let resolvedIndex: OCCore.WikiManager.Index

            do {
                try FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: learnedSkillsDirectory, withIntermediateDirectories: true)
                let memoryIndex = try OCCore.WikiManager.Index.load(articleRoots: [memoriesDirectory], skillRoots: [learnedSkillsDirectory])
                resolvedIndex = bundledIndex.combined(with: memoryIndex)
            } catch {
                print("⚠️ OpenClicky memory index load failed: \(error)")
                resolvedIndex = bundledIndex
            }

            await MainActor.run {
                self.bundledKnowledgeIndex = resolvedIndex
            }
        }
    }

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Called when the permission guide or first-run onboarding becomes visible
    /// to request the base voice permission.
    func requestPendingPermissionPrompts() {
        promptForMicrophoneIfNotDetermined()
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isRecordingFromMicrophoneButton,
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isKeyboardRecording, isMicrophoneButtonRecording, isFinalizing, isPreparing in
                guard let self else { return }

                // Don't let an old speaking state mask a real microphone
                // capture. Push-to-talk can interrupt speech and immediately
                // start listening; in that case the cursor must switch to the
                // waveform instead of staying in the response indicator.
                if self.voiceState == .responding,
                   !isKeyboardRecording,
                   !isMicrophoneButtonRecording,
                   !isFinalizing,
                   !isPreparing {
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isKeyboardRecording || isMicrophoneButtonRecording {
                    // Agent overlay / HUD Voice buttons use the microphone-
                    // button path, not the global keyboard shortcut path.
                    // Treat both as active listening so the cursor swaps to
                    // the recording waveform in every voice-capture entry.
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        compactChordCancellable = globalPushToTalkShortcutMonitor.compactChordPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.showExternalDictationInput(mode: mode) }

        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        shiftDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .shiftDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showMainOpenClickyPanelFromShortcut()
            }

        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyPressed()
            }
    }

    var compactInputAgentSessionID: UUID?
    @Published var sharedSessionStatus = "Disconnected"
    lazy var sharedCodexSession: CodexSharedSessionClient = {
        let client = CodexSharedSessionClient()
        client.onStatus = { [weak self] status in
            self?.sharedSessionStatus = status
            if status.hasPrefix("Waiting"), self?.currentResponseTask != nil {
                self?.updateVoiceResponseCaption("<cursor_reply>" + status + "</cursor_reply>", force: true, updatesDock: false)
            }
        }
        return client
    }()
    lazy var claudeCodeSessionLink: ClaudeCodeSessionLink = {
        let link = ClaudeCodeSessionLink()
        link.onStatus = { [weak self] status in self?.sharedSessionStatus = status }
        return link
    }()
    /// The linked Codex thread or Claude Code session (`claude:` prefix) of the selected compact task.
    var boundCodexThreadID: String? { compactInputAgentSessionID == nil ? companionConversations.active.boundThreadID : nil }

    /// Connect sources, shown in this order in the picker.
    lazy var sessionLinks: [SessionLink] = [
        CodexSessionLinkSource(client: { [unowned self] in self.sharedCodexSession }),
        ClaudeCodeSessionLinkSource(link: claudeCodeSessionLink)
    ]

}

#if DEBUG
extension CompanionManager {
    func setTestAgentDockItems(_ items: [ClickyAgentDockItem]) {
        self.agentDockItems = items
    }
    
    func setTestCodexAgentSessions(_ sessions: [CodexAgentSession]) {
        self.codexAgentSessions = sessions
    }
    
    func setTestHasMicrophonePermission(_ status: Bool) {
        self.hasMicrophonePermission = status
    }
    
    func setTestHasScreenContentPermission(_ status: Bool) {
        self.hasScreenContentPermission = status
    }

    static func testLocalAppOpenTarget(from transcript: String) -> String? {
        localAppOpenRequest(from: transcript)?.appName
    }

    static func testLocalFolderOpenTarget(from transcript: String) -> String? {
        localFolderOpenRequest(from: transcript)?.url.path
    }

    static func testLogEvidenceAnalysisInstruction(from transcript: String) -> String? {
        logEvidenceAnalysisInstruction(from: transcript)
    }

    static func testReminderCountInstruction(from transcript: String) -> String? {
        reminderCountRequest(from: transcript)?.instruction
    }

    static func testNativeKeyPress(from transcript: String) -> (key: String, modifiers: [String])? {
        guard let request = nativeKeyPressRequest(from: transcript) else { return nil }
        return (request.key, request.modifiers)
    }

    static func testNativeClick(from transcript: String) -> (targetPhrase: String?, prefersLastPointedElement: Bool)? {
        guard let request = nativeClickRequest(from: transcript) else { return nil }
        return (request.targetPhrase, request.prefersLastPointedElement)
    }

    static func testWebOpenTarget(from transcript: String) -> (url: String, browserAppName: String?)? {
        guard let request = webOpenRequest(from: transcript) else { return nil }
        return (request.url.absoluteString, request.browserAppName)
    }

    static func testCompositeAppAction(from transcript: String) -> (appName: String, actionText: String)? {
        guard let request = compositeAppActionRequest(from: transcript) else { return nil }
        return (request.appName, request.actionText)
    }

    static func testSpotifyPlaybackQuery(from transcript: String) -> String? {
        guard let request = compositeAppActionRequest(from: transcript),
              request.appName == "Spotify" else { return nil }
        return spotifyPlaybackQuery(from: request.actionText)
    }

    static func testStandaloneSpotifyPlaybackQuery(from transcript: String) -> String? {
        guard let request = standaloneSpotifyPlaybackRequest(from: transcript),
              request.appName == "Spotify" else { return nil }
        return spotifyPlaybackQuery(from: request.actionText)
    }

    static func testSpotifyPlaybackControlAction(from transcript: String) -> String? {
        guard let request = standaloneSpotifyPlaybackRequest(from: transcript),
              request.appName == "Spotify" else { return nil }
        return spotifyPlaybackControlAction(from: request.actionText)?.rawValue
    }

    static func testSystemVolumeControlAction(from transcript: String) -> String? {
        systemVolumeControlAction(from: transcript)?.rawValue
    }

    static func testSpotifySearchPlayExecutionMethods(
        for backend: OpenClickyComputerUseBackendID
    ) -> (started: String, completed: String) {
        let method = spotifySearchPlayExecutionMethod(for: backend)
        return (method, method)
    }

    static func testComputerUsePointingResolver(
        selectedVoiceModelID: String,
        selectedComputerUseModelID: String
    ) -> String {
        computerUsePointingResolver(
            selectedVoiceModelID: selectedVoiceModelID,
            selectedComputerUseModelID: selectedComputerUseModelID
        ).rawValue
    }

    static func testShouldAttachScreenContext(to transcript: String) -> Bool {
        shouldAttachScreenContext(to: transcript)
    }

    static func testIsScreenCalibrationRequest(_ transcript: String) -> Bool {
        isScreenCalibrationRequest(transcript)
    }

    static func testIsVisualGuidanceCalibrationCaption(_ caption: String?) -> Bool {
        isVisualGuidanceCalibrationCaption(caption)
    }

    static func testResetVisualGuidanceCalibration(for displayFrame: CGRect) {
        let defaults = UserDefaults.standard
        ["count", "offsetX", "offsetY"].forEach { suffix in
            defaults.removeObject(forKey: visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: suffix))
        }
    }

    static func testUpdateVisualGuidanceCalibrationOffset(delta: CGSize, for displayFrame: CGRect) -> CGSize {
        updatedVisualGuidanceCalibrationOffset(delta: delta, for: displayFrame).offset
    }

    static func testVisualGuidanceCalibrationOffset(for displayFrame: CGRect) -> CGSize {
        visualGuidanceCalibrationOffset(for: displayFrame)
    }

    static func testIsPlausibleVisualGuidanceCalibrationDelta(_ delta: CGSize, for displayFrame: CGRect) -> Bool {
        isPlausibleVisualGuidanceCalibrationDelta(delta, for: displayFrame)
    }

    static func testExpectedVisualGuidanceCalibrationCenter(
        caption: String,
        predictedRect: CGRect,
        screenFrame: CGRect,
        screenshotWidthInPixels: Int? = nil,
        screenshotHeightInPixels: Int? = nil
    ) -> CGPoint? {
        expectedVisualGuidanceCalibrationCenter(
            for: caption,
            predictedRect: predictedRect,
            screenFrame: screenFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
    }

    static func testParallelAgentInstructions(from instruction: String) -> [String] {
        parallelAgentInstructions(from: instruction)
    }

    static func testVoiceAgentStartFingerprint(instruction: String, route: String) -> String {
        voiceAgentStartFingerprint(instruction: instruction, route: route)
    }
}
#endif
