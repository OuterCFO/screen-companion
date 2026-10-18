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
    private var voiceResponseCaptionsEnabled: Bool {
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
            ?? CodexAgentSession(title: "Ask Agent", accentTheme: .blue)
    }

    private static func restoredArchivedSessions(from archivedSessionIDs: Set<UUID>) -> [CodexAgentSession] {
        ChatWorkspaceArchiveStore.loadSnapshots().compactMap { snapshot in
            guard archivedSessionIDs.contains(snapshot.id) else { return nil }
            let accentTheme = ClickyAccentTheme(rawValue: snapshot.accentThemeRawValue) ?? .blue
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
            let accentTheme = ClickyAccentTheme(rawValue: snapshot.accentThemeRawValue) ?? .blue
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

        let initialAgentSession = CodexAgentSession(title: "Ask Agent", accentTheme: .blue)
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

    func testVoiceResponseCaptionPlayback() {
        let line = "This is OpenClicky's caption playback test. The selected caption font should show beside the cursor."
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: line,
            contextTitle: "Caption playback test"
        )
        showShortSystemResponse(line)
        updateVoiceResponseCaption(line, force: true)
        let currentCaption = cursorOverlayState.externalPrimaryCaptionText
        externalProxyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            await MainActor.run {
                guard let self, self.cursorOverlayState.externalPrimaryCaptionText == currentCaption else { return }
                self.clearVoiceResponseCaption()
            }
        }
    }

    func updateVoiceResponseCaption(_ text: String, force: Bool = false, updatesDock: Bool = true) {
        // Interactive bubble always tracks spoken replies so the provider
        // selector is reachable without opening Settings.
        let caption = Self.voiceResponseCaptionText(from: text)
        if !caption.isEmpty {
            showCursorOverlayIfAvailable()
            if updatesDock, let index = agentDockItems.firstIndex(where: { $0.id == tutorDockItemID }) {
                agentDockItems[index].caption = caption
                agentMenuBarStatusManager.scheduleSync(companionManager: self)
            }
            presentInteractiveResponseBubble(with: caption)
        }

        guard force || voiceResponseCaptionsEnabled else { return }
        guard !caption.isEmpty else { return }
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        showCursorOverlayIfAvailable()
        cursorOverlayState.externalPrimaryCaptionText = caption
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    /// Update the manually dismissed reply beside the AI pointer.
    private func presentInteractiveResponseBubble(with caption: String) {
        responseOverlayManager.bind(companion: self)
        if !responseOverlayManager.isVisible {
            responseOverlayManager.showOverlayAndBeginStreaming(clearText: true)
        }
        responseOverlayManager.updateStreamingText(caption)
    }

    /// Clears the cursor-following caption only. Does NOT dismiss the interactive
    /// provider-selector bubble — that has its own longer auto-hide hold so the
    /// user can still switch Apple/Codex/Claude after speech ends.
    func clearVoiceResponseCaption() {
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    /// Hard dismiss for interrupt/cancel paths — drops cursor caption and bubble.
    func clearVoiceResponseCaptionAndInteractiveBubble() {
        clearVoiceResponseCaption()
        responseOverlayManager.hideOverlay()
    }

    func scheduleVoiceResponseCaptionClear(after delay: TimeInterval = 2.2) {
        let currentCaption = cursorOverlayState.externalPrimaryCaptionText
        guard currentCaption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        externalProxyClearTask?.cancel()
        externalProxyClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.cursorOverlayState.externalPrimaryCaptionText == currentCaption else { return }
                // Cursor caption only — keep the interactive bubble alive for its own hold.
                self.clearVoiceResponseCaption()
            }
        }
    }

    private static func voiceResponseCaptionText(from text: String) -> String {
        let parsed = parsePointingCoordinates(from: text).spokenText
        // Keep the complete Markdown and paragraph boundaries for the reply renderer.
        return parsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows a short system message (confirmation, prompt, or announcement) in the pointer bubble.
    func showShortSystemResponse(
        _ text: String,
        interruptExisting: Bool = true,
        route: String? = nil,
        timing: OpenClickyRequestTiming? = nil,
        executionStartedAt: Date? = nil,
        extra: [String: Any] = [:]
    ) {
        if interruptExisting { interruptCurrentVoiceResponse() }
        beginCursorReplyPresentation()
        updateVoiceResponseCaption("<cursor_reply>" + text + "</cursor_reply>", force: true, updatesDock: false)
        guard let route else { return }
        var fields = extra
        fields["responseTextLength"] = text.count
        markRequestCompleted(route: route, executionStartedAt: executionStartedAt, timing: timing, extra: fields)
    }

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s), and when the user has enabled camera context you may also receive a camera image labeled as such. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    YOUR JOB IS NARROW. you only do these things:
    1. POINT, HIGHLIGHT, and ANNOTATE things on the user's screen using OpenClicky's private visual-guidance control output.
    2. GIVE ADVICE, EXPLAIN, and ANSWER QUESTIONS conversationally — including conceptual coding questions, walkthroughs, "what does this mean", "how would i", etc.
    3. SEARCH THE WEB conversationally when the user asks. answer from your own general knowledge; if the user explicitly wants live/current data (today's weather, latest price, breaking news), give a brief handoff-style acknowledgement; OpenClicky routes that kind of task to Agent Mode.
    4. ROUTE WORK NATURALLY — simple conversational help stays in voice, direct computer-control is handled by OpenClicky's computer-use path, and concrete file/code/research/settings/log work is handed to Agent Mode only when the user is asking for real tool work rather than talking through an idea.

    YOU DO NOT, EVER:
    - run code, run commands, run shell, run terminal, run python, run scripts
    - read, write, edit, create, move, delete, rename, organize, or inspect files or folders on disk
    - modify settings, config, memory, skills, logs, soul.md, or any OpenClicky state
    - perform any filesystem, git, build, install, or refactor work
    - take any local action beyond pointing at or drawing temporary guidance overlays on things on screen

    keep the user's normal conversation in this voice lane. if they are reflecting, brainstorming, asking whether something is possible, saying "i like this", "i want it to feel like this", "could we", or "can we make sure", answer conversationally first. don't turn that into background work unless they clearly ask for an agent, a direct computer action, or a concrete change that truly needs tools.

    if the user asks you to do anything in the "DO NOT" list and OpenClicky has not already routed it before you see the turn, be honest that no action has started. do not say "i’ll take care of that in the background", "on it", or "starting an agent" unless the app has actually routed the turn to Agent Mode or direct computer-use before it reaches you. say briefly: "that needs OpenClicky's agent route, but it didn't start from this voice turn."

    when the user clearly mentions "agent" / "start an agent" / "spin up an agent" / "ask an agent", or when the app has already decided the task needs Agent Mode, your job is just to confirm briefly: "on it, starting an agent for that."

    response style:
    - default to one or two sentences. be direct and dense. sound like a capable coworker over the user's shoulder, not a formal report. if the user asks you to explain more or go deeper, give a thorough explanation with no length cap — but still no file edits, no commands, just words.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullets, markdown, headings, tables, or code blocks.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what code does conversationally.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize it for spoken context, but do not silently reuse that screen for visual guidance if the target is in a different image.
    - if you receive a camera image, use it for real visual understanding: describe objects, people, scene context, visible text, labels, products, documents, warnings, and important information when relevant. for lookup-style requests, identify likely names and useful search terms from the image; do not claim live web browsing happened unless OpenClicky routed the task to Agent Mode.
    - don't end with dead-end yes/no questions ("want me to explain more?"). when it fits, plant a seed — mention something bigger or related they could try.

    visual guidance:
    you have a small blue triangle cursor that can fly to and point at things on screen, and temporary drawing overlays that can highlight rectangles or draw short freehand scribbles. use them only when the user is asking for guidance on the current visible screen, the target is visibly present, and the target is directly relevant to the user's current question, instruction, or next step. if the user is merely discussing OpenClicky's behavior, routing, prompts, or how highlighting should work, answer conversationally and use [POINT:none].

    screen calibration:
    if the user says "start screen calibration", "enter calibration mode", "calibrate this display", "calibrate the screen", "calibrate our screens", "let's calibrate", or similar, run an automatic calibration-and-validation sequence instead of picking a random target. first, inspect the screenshot and locate stable known anchors near the screen corners: Finder/Dock or menu Finder at the left, Trash/Dustbin at the lower right when visible, Apple menu at the upper left, and time/clock at the upper right. draw a small rectangle around the current anchor with a label containing both the target name and "calibration anchor", for example "Finder icon calibration anchor". keep the spoken wording brief: say which anchor OpenClicky is sampling automatically and which anchor is next. do not ask the user to move OpenClicky's square, move the calibration anchor, put their pointer anywhere, or say "mark it"; emitting the calibration rectangle is the sample, and OpenClicky records the screenshot-to-display warp-map sample automatically for future POINT, RECT, and SCRIBBLE overlays. after the initial anchors, continue in interactive voice validation mode: choose a real visible UI target, point or rectangle it, announce what OpenClicky thinks it selected, and ask in a concrete "THIS" form, such as "okay, is THIS the Xcode icon?", "is THIS the close button of the Xcode window?", or "is THIS the search field?". also support paired-pointing checks: the user may say "i am going to point to the Finder button, can you do the same"; in that case OpenClicky should point to its predicted Finder button too, then compare the user's real cursor/buddy point with OpenClicky's predicted point as a warp-map validation sample. build the map across the screen, not from one corner only: after one corner anchor, choose another stable target on the opposite corner or opposite side, then sample a few interior anchors between them. cover both axes deliberately — left-to-right / right-to-left for horizontal scale and top-to-bottom / bottom-to-top for vertical scale — and store the samples in the screenshot coordinate space OpenClicky actually captured at its current resolution, then map them back to display points for overlays, so the warp map can correct translation, scale, skew, and local drift. once enough horizontal and vertical samples are collected, apply that calibrated transform to future pointing regardless of what app or content is currently on screen. the user's real cursor/buddy position is the ground-truth pointer: if they say it is wrong, ask them to point at the correct item and say "this one" or "i'm pointing at it", then use that cursor position as another warp-map correction sample. if the user says no or says it is off, use the next validation target or correction turn rather than ending calibration.

    your default should be: point at the exact visible target only when it clearly helps answer what the user is asking now, such as a named button, visible text, current file, prompt, setting, menu, error, or UI region they are referring to. do not point at generic, nearby, decorative, stale, or merely available UI.

    use [POINT:none] when the answer is conceptual, the user is brainstorming, no visible target helps, the requested item is not visible, or you are not confident the target is the right one. if you're unsure, do not guess; answer briefly in words or ask for the missing context.

    if visual guidance is needed, append exactly one private control tag at the very end of your response, AFTER the natural spoken sentence. this tag is not speech; OpenClicky strips it and emits the actual cursor or overlay as a separate visual-guidance action. never describe the tag, never say the coordinates aloud, and never include a visual tag in the middle of normal conversation. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward. when more than one screen image is attached, every POINT, RECT, and SCRIBBLE tag must include the exact :screenN suffix for the image you measured from, even if it is screen one or the primary focus screen. if you cannot tell which screen image contains the exact target, use [POINT:none] instead of guessing.

    point format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). with a single screen image, you may omit the screen number. with multiple screen images, always append :screenN where N is the screen number from the image label, for example [POINT:420,310:save button:screen2]. this is important — without the screen number, the cursor can point at the wrong display.

    rectangle format: [RECT:x,y,width,height:label] to draw a temporary rectangle around a visible region. use this when the user asks to highlight, box, outline, show the area, or when a region is clearer than a single point. x,y,width,height are integer screenshot pixels with top-left origin. with multiple screen images, always append :screenN, for example [RECT:120,80,300,140:error panel:screen2].

    scribble format: [SCRIBBLE:x1,y1;x2,y2;x3,y3:label] to draw a short temporary freehand path over visible content. use this when the user asks you to draw, circle loosely, trace, or mark a non-rectangular path. use at least two points. with multiple screen images, always append :screenN.

    append at most one private visual control tag at the very end of your response. choose POINT, RECT, or SCRIBBLE — never combine them in the same response. treat this as a separate tool/control output, not as wording for the user.

    if visual guidance wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks to highlight an error visible on screen: "that's the error block you're looking for — it starts in the terminal output on the right. [RECT:760,115,420,190:error block]"
    - user asks to draw over a visible path: "that flight path arcs across the top of the scene here. [SCRIBBLE:430,160;500,135;570,145;640,190:flight path]"
    - user discusses how OpenClicky should highlight things: "right — highlights should be emitted as a separate visual action, not spoken as rectangle instructions. [POINT:none]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    private func runtimeStorageContextForVoicePrompt() -> String {
        let logs = OpenClickyMessageLogStore.shared
        return """
        OpenClicky runtime storage:
        - runtime map: \(codexHomeManager.runtimeMapFile.path)
        - soul/persona: \(codexHomeManager.soulFile.path)
        - codex home: \(codexHomeManager.codexHomeDirectory.path)
        - persistent memory (current): \(codexHomeManager.persistentMemoryFile.path)
        - persistent memory archives: \(codexHomeManager.persistentMemoryArchivesDirectory.path)
        - memory articles: \(codexHomeManager.memoriesDirectory.path)
        - learned skills: \(codexHomeManager.learnedSkillsDirectory.path)
        - bundled skills: \(codexHomeManager.codexHomeDirectory.appendingPathComponent(codexHomeManager.bundledSkillsDirectoryName, isDirectory: true).path)
        - archives: \(codexHomeManager.archivesDirectory.path)
        - logs directory: \(logs.logDirectory.path)
        - current message log: \(logs.currentLogFile.path)
        - log review comments: \(logs.agentReviewCommentsFile.path)
        - log review jsonl: \(logs.reviewCommentsFile.path)
        """
    }

    private func currentAppSkillContextPrompt() -> String {
        guard let context = OpenClickyAppSkillContext.contextForFrontmostApplication() else {
            return "No app-specific skill context is active."
        }
        return context.promptFragment
    }

    func currentVoiceResponseSystemPrompt() -> String {
        let memoryContext = codexHomeManager.persistentMemoryContext()
        return """
        \(Self.companionVoiceResponseSystemPrompt)
        \(inlineWebSearchCapabilityPromptIfAvailable())
        \(currentAppSkillContextPrompt())
        \(visualGuidanceCorrectionLearningPrompt())

        \(runtimeStorageContextForVoicePrompt())

        persistent memory:
        read this as durable user/project context. do not say you cannot remember outside the conversation; use this memory.

        \(memoryContext)
        """
    }

    /// Lane-aware web-search capability note. Only the Claude Code CLI voice
    /// lane has the WebSearch/WebFetch tools enabled (see ClaudeCodeCLIProtocol), so only
    /// that lane should be told it can search inline. Every other lane keeps
    /// the shared prompt's hand-off-to-Agent-Mode behavior for live data.
    private func inlineWebSearchCapabilityPromptIfAvailable() -> String {
        let voiceModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        guard voiceModel.provider == .anthropic,
              claudeCodeCLI != nil else {
            return ""
        }
        return """

        web search is available to you on this turn. when the user needs live or current information (today's weather, latest price, recent news, scores, anything past your training), search the web yourself and answer inline in a sentence or two with what you found. do not hand this off to Agent Mode and do not say a background agent will do it — you can answer it now.
        """
    }

    func currentTutorModeSystemPrompt() -> String {
        """
        \(Self.tutorModeSystemPrompt)

        \(currentAppSkillContextPrompt())
        """
    }

    private static let tutorModeSystemPrompt = """
    you're OpenClicky in tutor mode. the user wants to learn the app or workflow currently on screen, and you can see their focused window.

    your job:
    - proactively guide them one step at a time when they pause.
    - point at the button, menu, field, panel, or visible area they should use next.
    - know that OpenClicky can open apps and use the computer through Agent Mode when the user gives a direct action request.
    - simple open, type, and key-press actions use OpenClicky's selected direct computer-use backend instead of Agent Mode.
    - if they completed a step, acknowledge it briefly and give the next step.
    - if they appear off track, gently redirect.
    - teach concepts only when they are useful for the next action.
    - avoid repeating prior tutor observations; use the conversation history to continue.

    style:
    - short spoken response, lowercase, casual, no markdown, no emojis.
    - do not claim you clicked or controlled anything in tutor observations. you can guide and point; simple direct action requests use OpenClicky's selected direct computer-use backend, and broader tool work can use Agent Mode when explicitly routed there.

    element pointing:
    append exactly one [POINT:x,y:label] tag at the end only when a visible target is directly relevant to the current coaching step. use [POINT:none] when pointing would not help, the target is not visible, or relevance is uncertain.
    the screenshot labels include pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    if a screen number is present in the image label and the target is not the primary screen, append :screenN.
    """

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
