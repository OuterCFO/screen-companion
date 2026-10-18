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
    @Published private(set) var codexAgentSessions: [CodexAgentSession]
    @Published private(set) var activeCodexAgentSessionID: UUID
    /// Session IDs the user has archived from the chat sidebar. Persisted to UserDefaults.
    /// Archived sessions remain in `codexAgentSessions` so transcripts/state are preserved;
    /// the sidebar simply hides them under an Archived section.
    @Published private(set) var archivedSessionIDs: Set<UUID> = ChatWorkspaceArchiveStore.load()
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
    private var pendingAgentVoiceFollowUpSessionID: UUID?
    private var pendingAgentVoiceFollowUpCreatedAt: Date?
    private var pendingAgentVoiceFollowUpSource: String?
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
    private static let pendingAgentOfferTTL: TimeInterval = 90
    static let deferredLiveAgentRoutePartialTTL: TimeInterval = 20

    /// Guards against a single voice utterance launching the same agent
    /// task twice when overlapping routes both resolve to an agent start.
    private var lastVoiceAgentStartFingerprint: String?
    private var lastVoiceAgentStartAt: Date?
    private var lastVoiceAgentStartSessionID: UUID?
    private var suppressNextVoiceAgentStartAcknowledgement = false
    private static let voiceAgentStartDuplicateTTL: TimeInterval = 8

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
    private var lastAgentContextSessionID: UUID?
    private var announcedAgentFileURLs: Set<String> = []
    private var pendingSystemAnnouncementTask: Task<Void, Never>?
    private var pendingSystemAnnouncementSessionID: UUID?
    private var speakingSystemAnnouncementSessionID: UUID?
    private var silencedAgentSpeechSessionIDs: Set<UUID> = []
    var liveHandledComputerUseFingerprints: Set<String> = []
    private var lastAgentProgressNarrationAt: Date?
    /// The phrase last spoken for each running agent session, keyed by
    /// session ID. Used to suppress duplicate progress narrations — we
    /// only speak when the *content* of the activity changed, never just
    /// because a polling tick fired.
    private var lastAgentProgressNarrationSignatures: [UUID: String] = [:]
    private static let agentProgressVoiceUpdatesDefaultsKey = "agentProgressVoiceUpdatesEnabled"
    var currentFolderContextURL: URL?
    var activeRequestTiming: OpenClickyRequestTiming?
    private var agentRequestTimingsBySessionID: [UUID: OpenClickyRequestTiming] = [:]
    private var agentExecutionStartDatesBySessionID: [UUID: Date] = [:]
    /// Agent tasks started since launch; only their results are shown by the pointer, not restored older tasks.
    private var agentSessionsStartedThisLaunch = Set<UUID>()
    /// Sessions whose terminal outcome (success, failure, cancellation) has
    /// already been narrated — so we don't re-announce on every Combine republish.
    /// Stores outcome labels like "success", "failed", "cancelled".
    private var lastNarratedAgentOutcomeBySessionID: [UUID: String] = [:]

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
    private var agentTaskBubbleClearTask: Task<Void, Never>?
    var externalPrimaryCursorMoveTask: Task<Void, Never>?
    var externalSecondaryCursorClearTasks: [UUID: Task<Void, Never>] = [:]
    var visualGuidanceOverlayClearTasks: [UUID: Task<Void, Never>] = [:]
    var pendingVisualGuidanceCalibrationAnchor: OpenClickyPendingVisualGuidanceCalibrationAnchor?
    var activeControlGlowClearTask: Task<Void, Never>?
    private var agentStatusCancellables: [UUID: AnyCancellable] = [:]
    private var agentActivityCancellables: [UUID: AnyCancellable] = [:]
    private var agentLoopActivityCancellables: [UUID: AnyCancellable] = [:]
    private var agentProgressStageCancellables: [UUID: AnyCancellable] = [:]
    private var agentTitleCancellables: [UUID: AnyCancellable] = [:]
    private var pendingAgentActivityRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRelaunchableSnapshotPersistTask: Task<Void, Never>?
    private var pendingRelaunchableAgentResumeTask: Task<Void, Never>?
    private var relaunchableAgentResumeTimer: Timer?
    private var autoResumedRelaunchSessionIDs: Set<UUID> = []
    var tutorIdleCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var pendingAgentDockItemRemovalTasks: [UUID: DispatchWorkItem] = [:]

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
    private let cancelledDockItemHoldDuration: TimeInterval = 0.45
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

    private func bindAgentSessionObservation() {
        codexAgentSessions.forEach { observeCodexAgentSession($0) }
    }

    private func observeCodexAgentSession(_ session: CodexAgentSession) {
        guard agentStatusCancellables[session.id] == nil else { return }

        session.onOpenableFileFound = { [weak self, weak session] fileURL in
            guard let self, let session else { return }
            self.handleAgentFoundOpenableFile(fileURL, session: session)
        }

        agentStatusCancellables[session.id] = session.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] status in
                guard let self else { return }
                if status != .stopped {
                    self.cancelPendingAgentDockItemRemoval(for: sessionID)
                }
                self.updateAgentDockItem(for: sessionID, status: status)
                self.scheduleStatusSync()
                self.scheduleRelaunchableAgentSessionsPersist()
                self.updateAgentProgressNarration()
            }

        agentActivityCancellables[session.id] = session.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
                self?.scheduleRelaunchableAgentSessionsPersist()
            }

        agentLoopActivityCancellables[session.id] = session.$activityStatusLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
            }

        agentProgressStageCancellables[session.id] = session.$progressStage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRelaunchableAgentSessionsPersist()
            }

        agentTitleCancellables[session.id] = session.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] title in
                self?.updateAgentDockTitle(for: sessionID, title: title)
                self?.scheduleRelaunchableAgentSessionsPersist()
            }
    }

    private func persistRelaunchableAgentSessions() {
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = nil
        ChatWorkspaceArchiveStore.saveRelaunchableSnapshots(
            for: codexAgentSessions,
            archivedSessionIDs: archivedSessionIDs
        )
    }

    private func scheduleRelaunchableAgentSessionsPersist() {
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.persistRelaunchableAgentSessions()
            }
        }
    }

    private func startRelaunchableAgentAutoResumeChecks() {
        relaunchableAgentResumeTimer?.invalidate()
        scheduleRelaunchableAgentAutoResumeCheck(trigger: "startup")

        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRelaunchableAgentAutoResumeCheck(trigger: "periodic")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        relaunchableAgentResumeTimer = timer
    }

    private func scheduleRelaunchableAgentAutoResumeCheck(trigger: String) {
        pendingRelaunchableAgentResumeTask?.cancel()
        pendingRelaunchableAgentResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(trigger == "startup" ? 1500 : 250))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.resumeRestoredAgentTasksIfNeeded(trigger: trigger)
            }
        }
    }

    private func resumeRestoredAgentTasksIfNeeded(trigger: String) {
        pendingRelaunchableAgentResumeTask = nil
        let sessionsToResume = codexAgentSessions.filter { session in
            session.canResumeAfterRelaunch
                && !archivedSessionIDs.contains(session.id)
                && !autoResumedRelaunchSessionIDs.contains(session.id)
        }
        guard !sessionsToResume.isEmpty else { return }

        let ids = sessionsToResume.map(\.id)
        autoResumedRelaunchSessionIDs.formUnion(ids)
        activeCodexAgentSessionID = ids.first ?? activeCodexAgentSessionID
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.auto_resume",
            fields: [
                "trigger": trigger,
                "count": sessionsToResume.count,
                "sessionIDs": ids.map(\.uuidString),
                "titles": sessionsToResume.map(\.title)
            ]
        )

        sessionsToResume.forEach { session in
            updateAgentDockItem(for: session.id, status: session.status)
            session.resumeInterruptedTaskAfterRelaunch()
        }
        scheduleStatusSync()
        scheduleRelaunchableAgentSessionsPersist()
    }

    private func updateAgentDockTitle(for sessionID: UUID, title: String) {
        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, agentDockItems[itemIndex].title != trimmedTitle else { return }
        agentDockItems[itemIndex].title = trimmedTitle
        scheduleStatusSync()
    }

    private func scheduleAgentActivityRefresh(for sessionID: UUID) {
        guard pendingAgentActivityRefreshTasks[sessionID] == nil else { return }

        // Short debounce so streaming assistant deltas feel real-time in the
        // dock caption. The old 450ms interval batched too aggressively and
        // produced visibly "stalled" updates while tokens were arriving.
        pendingAgentActivityRefreshTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                guard let self else { return }
                self.pendingAgentActivityRefreshTasks[sessionID] = nil
                guard let session = self.codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
                self.updateAgentDockItem(for: sessionID, status: session.status)
                self.scheduleStatusSync()
                self.updateAgentProgressNarration()
            }
        }
    }

    @discardableResult
    func createAndSelectNewCodexAgentSession(title: String? = nil, accentTheme: ClickyAccentTheme? = nil) -> CodexAgentSession {
        let resolvedAccentTheme = accentTheme ?? Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
        // Inject the Claude Code CLI client so title generation
        // follows the money rule (SDK first, direct REST fallback). See
        // CodexAgentSession.fastFriendlyTitle.
        let session = CodexAgentSession(
            title: title ?? "Ask Agent",
            accentTheme: resolvedAccentTheme,
            claudeCodeCLI: claudeCodeCLI
        )
        codexAgentSessions.append(session)
        observeCodexAgentSession(session)
        activeCodexAgentSessionID = session.id
        lastAgentContextSessionID = session.id
        scheduleStatusSync()
        scheduleRelaunchableAgentSessionsPersist()
        return session
    }

    private func resolvedNewAgentTaskPrompt(from prompt: String) -> String {
        let explicitInstruction = Self.agentTaskCreationInstruction(from: prompt)
            ?? Self.permissiveAgentInstruction(from: prompt)
            ?? Self.clickyAgentInstruction(from: prompt)
        guard let explicitInstruction else { return prompt }

        var instruction = SpokenText.normalizedAgentTaskInstruction(from: explicitInstruction)
        if Self.isReferentialAgentInstruction(instruction),
           let resolvedInstruction = referentialAgentInstructionContext(excluding: prompt) {
            instruction = resolvedInstruction
        }

        instruction = SpokenText.cleanedAgentTaskInstruction(instruction)
        guard !instruction.isEmpty,
              !Self.isAgentTaskPlaceholderInstruction(instruction) else {
            return prompt
        }
        return instruction
    }

    /// Creates a brand-new agent session, stages it into the same dock/menu
    /// surfaces as a normal agent task, then submits the initial prompt.
    @discardableResult
    func createAndLaunchCodexAgentSession(
        title: String? = nil,
        prompt: String,
        accentTheme: ClickyAccentTheme? = nil,
        includeScreenContext: Bool = true,
        restrictedExecutionPolicy: Bool = false
    ) -> CodexAgentSession {
        let session = createAndSelectNewCodexAgentSession(title: title, accentTheme: accentTheme)
        if restrictedExecutionPolicy {
            session.configureRestrictedExecutionPolicy()
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return session }
        stageDashboardAgentSubmission(prompt: trimmedPrompt, session: session)
        submitAgentPrompt(trimmedPrompt, to: session, includeScreenContext: includeScreenContext)
        return session
    }

    private func handleAgentFoundOpenableFile(_ fileURL: URL, session: CodexAgentSession) {
        let standardizedURL = fileURL.standardizedFileURL
        let eventKey = "\(session.id.uuidString)|\(standardizedURL.path)"
        guard !announcedAgentFileURLs.contains(eventKey) else { return }

        announcedAgentFileURLs.insert(eventKey)
        openOpenClickyDocument(standardizedURL)
        showShortSystemResponse("\(session.spokenAgentSentenceName) says it found \(Self.spokenFileName(for: standardizedURL)), showing it now.")
    }

    static func isMarkdownDocument(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    private static func spokenFileName(for fileURL: URL) -> String {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let cleanedName = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleanedName.isEmpty ? "the file" : cleanedName
    }

    func selectCodexAgentSession(_ sessionID: UUID) {
        guard codexAgentSessions.contains(where: { $0.id == sessionID }) else { return }
        activeCodexAgentSessionID = sessionID
        lastAgentContextSessionID = sessionID
    }

    /// Mark a session as archived. Keeps the session alive so its transcript and state
    /// are preserved; the sidebar groups archived sessions under a separate header.
    func archiveSession(_ sessionID: UUID, allowIncomplete: Bool = false) {
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
        let isActivelyRunning: Bool = {
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }()
        guard !isActivelyRunning, !session.isTurnActiveForChatQueue else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.archive_blocked_running",
                fields: [
                    "sessionID": sessionID.uuidString,
                    "title": session.title
                ]
            )
            return
        }
        guard allowIncomplete || session.isFinishedForArchive else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.archive_blocked_incomplete",
                fields: [
                    "sessionID": sessionID.uuidString,
                    "title": session.title,
                    "progressStage": session.progressStage.label
                ]
            )
            return
        }
        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.insert(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.saveSnapshot(for: session)
        ChatWorkspaceArchiveStore.removeRelaunchableSnapshot(for: sessionID)
        cancelPendingAgentDockItemRemoval(for: sessionID)
        silenceAgentSpeech(for: sessionID, reason: "agent_session_archived")
        agentDockItems.removeAll { $0.sessionID == sessionID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        refreshAgentDockFollowBehavior()
        if activeCodexAgentSessionID == sessionID {
            if let next = codexAgentSessions.first(where: { !archivedSessionIDs.contains($0.id) }) {
                selectCodexAgentSession(next.id)
            } else {
                _ = createAndSelectNewCodexAgentSession()
            }
        }
        scheduleStatusSync()
    }

    /// Restore a previously archived session.
    func unarchiveSession(_ sessionID: UUID) {
        guard archivedSessionIDs.contains(sessionID) else { return }
        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.remove(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.removeSnapshot(for: sessionID)
        persistRelaunchableAgentSessions()
        scheduleStatusSync()
    }

    /// Pop the currently active session into a floating mini-chat NSPanel scoped to that session.
    /// The mini-chat dies with the parent HUD via `MiniChatPanelManager.shared.destroyAll()`.
    func popoutCurrentSession() {
        let session = codexAgentSession
        MiniChatPanelManager.shared.show(session: session, companion: self)
    }

    /// Launch a new chat session pre-configured as a specialist OpenClicky
    /// agent. The agent's soul/instructions/memory are layered into the
    /// session's system prompt via `prependedSystemContext`.
    @discardableResult
    func createAndSelectNewCodexAgentSession(asAgent agent: OpenClickyAgentDefinition) -> CodexAgentSession {
        let session = createAndSelectNewCodexAgentSession(title: agent.metadata.displayName)
        session.prependedSystemContext = agent.renderedSystemContext()
        session.specialistAgentSlug = agent.slug
        return session
    }

    func closeCodexAgentSession(_ sessionID: UUID) {
        guard let closingIndex = codexAgentSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let closingSession = codexAgentSessions[closingIndex]
        closingSession.stop(reason: "chat_session_closed")
        closingSession.onOpenableFileFound = nil

        cancelPendingAgentDockItemRemoval(for: sessionID)
        pendingAgentActivityRefreshTasks[sessionID]?.cancel()
        pendingAgentActivityRefreshTasks.removeValue(forKey: sessionID)
        pendingAgentDockItemRemovalTasks.removeValue(forKey: sessionID)
        agentStatusCancellables.removeValue(forKey: sessionID)
        agentActivityCancellables.removeValue(forKey: sessionID)
        agentLoopActivityCancellables.removeValue(forKey: sessionID)
        agentProgressStageCancellables.removeValue(forKey: sessionID)
        agentTitleCancellables.removeValue(forKey: sessionID)
        agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        lastNarratedAgentOutcomeBySessionID.removeValue(forKey: sessionID)

        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.remove(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.removeSnapshot(for: sessionID)
        ChatWorkspaceArchiveStore.removeRelaunchableSnapshot(for: sessionID)

        codexAgentSessions.remove(at: closingIndex)
        agentDockItems.removeAll { $0.sessionID == sessionID }

        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
        }
        if lastAgentContextSessionID == sessionID {
            lastAgentContextSessionID = nil
        }

        if codexAgentSessions.isEmpty {
            _ = createAndSelectNewCodexAgentSession()
        } else if activeCodexAgentSessionID == sessionID {
            let fallbackIndex = min(closingIndex, codexAgentSessions.count - 1)
            selectCodexAgentSession(codexAgentSessions[fallbackIndex].id)
        }

        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_session.closed",
            fields: [
                "sessionID": sessionID.uuidString,
                "title": closingSession.title
            ]
        )
        scheduleStatusSync()
        persistRelaunchableAgentSessions()
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

    func submitPendingAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard let sessionID = pendingAgentVoiceFollowUpSessionID else { return false }
        let pendingSource = pendingAgentVoiceFollowUpSource ?? "pending_voice_followup"
        if let createdAt = pendingAgentVoiceFollowUpCreatedAt,
           Date().timeIntervalSince(createdAt) > Self.pendingAgentVoiceFollowUpTTL {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_followup.voice_target_expired",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "ageMs": Int(Date().timeIntervalSince(createdAt) * 1000)
                ]
            )
            return false
        }
        if Self.shouldStartNewAgentInsteadOfPendingFollowUp(trimmedTranscript) {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_followup.bypassed_for_new_agent_request",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "instructionPreview": String(trimmedTranscript.prefix(160)),
                    "requestID": activeRequestTiming?.requestID ?? ""
                ]
            )
            return false
        }
        if Self.isProbablyIncompleteAgentVoiceFollowUp(trimmedTranscript) {
            let timing = activeRequestTiming
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_followup.deferred_incomplete_voice",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "requestID": timing?.requestID ?? "",
                    "instructionLength": trimmedTranscript.count,
                    "instructionPreview": String(trimmedTranscript.prefix(120))
                ]
            )
            showShortSystemResponse("i only caught part of that. try the agent follow-up again.")
            return true
        }
        // The user explicitly targeted an agent from the dock/HUD — either by
        // opening its overlay or pressing Voice — so the next utterance belongs
        // to that agent even if it sounds like a normal local OpenClicky
        // command such as “open Clicky.” Keep this ahead of new-task, direct
        // computer-use, and quick local routing.
        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        pendingAgentVoiceFollowUpSource = nil
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": pendingSource,
                "sessionID": sessionID.uuidString,
                "instructionLength": trimmedTranscript.count
            ]
        )

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            showShortSystemResponse("i lost track of that agent. open the agent dock and try again.")
            markRequestCompleted(
                route: "agent.followup",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "CodexAgentSession.lookup",
                    "controller": "CompanionManager",
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "error": "Missing agent session"
                ]
            )
            return true
        }

        selectCodexAgentSession(sessionID)
        submitAgentPrompt(trimmedTranscript, to: session)
        lastAgentContextSessionID = sessionID
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": pendingSource,
                "sessionID": sessionID.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        showShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    private static func isProbablyIncompleteAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return true }

        let danglingSuffixes = [
            "where the agent",
            "where the agents",
            "when the agent",
            "when the agents",
            "that the agent",
            "that the agents",
            "because the agent",
            "because the agents",
            "where it",
            "when it",
            "because it",
            "so it",
            "and it",
            "but it",
            "where",
            "when",
            "because",
            "that",
            "so",
            "and",
            "but"
        ]
        if danglingSuffixes.contains(where: { normalized.hasSuffix($0) }) {
            return true
        }

        let trailingFunctionWords: Set<String> = [
            "the", "a", "an", "to", "for", "with", "of", "in", "on", "at", "from",
            "by", "as", "into", "about", "around", "through", "over", "under"
        ]
        if let lastWord = normalized.split(separator: " ").last,
           trailingFunctionWords.contains(String(lastWord)) {
            return true
        }

        if isMostlySpokenTimestampOrLogNoise(normalized) {
            return true
        }

        return false
    }

    private static func isMostlySpokenTimestampOrLogNoise(_ normalizedTranscript: String) -> Bool {
        let words = normalizedTranscript.split(separator: " ").map(String.init)
        guard words.count >= 5 else { return false }

        let timestampTokens: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "oh", "o", "t", "z", "am", "pm"
        ]
        let timestampTokenCount = words.filter { timestampTokens.contains($0) }.count
        let timestampTokenRatio = Double(timestampTokenCount) / Double(words.count)

        let hasSpokenDateShape = normalizedTranscript.contains("zero five one zero")
            || normalizedTranscript.contains("zero two six")
            || normalizedTranscript.contains("two zero two six")
            || normalizedTranscript.contains("t one four")
            || normalizedTranscript.contains("t fourteen")

        let usefulWorkPattern = #"\b(?:fix|change|update|add|remove|make|create|build|open|show|find|review|test|run|check|look|inspect|capture|move|point|write|send)\b"#
        let hasUsefulWorkVerb = normalizedTranscript.range(of: usefulWorkPattern, options: .regularExpression) != nil

        return hasSpokenDateShape
            && timestampTokenRatio >= 0.35
            && !hasUsefulWorkVerb
    }

    private static func shouldStartNewAgentInsteadOfPendingFollowUp(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard normalized.contains("agent") || normalized.contains("agents") else { return false }
        if explicitNewTaskInstruction(from: transcript) != nil { return true }
        if agentTaskCreationInstruction(from: transcript) != nil { return true }

        let delegationPattern = #"\b(?:get|put|start|spin\s+up|spawn|create|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+|another\s+|new\s+|background\s+)*(?:agent|agents|codex)\b"#
        return normalized.range(of: delegationPattern, options: .regularExpression) != nil
    }

    func submitContextualAgentFollowUp(_ transcript: String, source: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard !Self.isExplicitNewTaskRequest(trimmedTranscript) else { return false }
        // Require an actual follow-up cue — a connector word, the literal
        // word "agent", or a clearly-imperative micro-utterance. Without
        // this gate, any random question (e.g. "can you search the web?")
        // gets eaten by a still-running agent purely because it exists.
        guard Self.isLikelyAgentFollowUpPhrasing(trimmedTranscript) else { return false }
        guard let session = latestSteerableAgentSession() else { return false }
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedTranscript.count
            ]
        )

        selectCodexAgentSession(session.id)
        submitAgentPrompt(trimmedTranscript, to: session)
        lastAgentContextSessionID = session.id
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_followup.steered",
            fields: [
                "sessionID": session.id.uuidString,
                "title": session.title,
                "source": source,
                "instruction": trimmedTranscript
            ]
        )
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        showShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    func handleAgentSelectionRequestIfNeeded(from transcript: String, source: String) -> Bool {
        guard let request = Self.agentSelectionRequest(from: transcript) else { return false }
        let timing = activeRequestTiming
        let route = request.followUpText == nil ? "agent.select" : "agent.select_and_followup"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.selectCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "agentName": request.agentName,
                "hasFollowUpText": request.followUpText != nil
            ]
        )

        guard let session = agentSession(matchingSpokenName: request.agentName) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_select.not_found",
                fields: [
                    "source": source,
                    "agentName": request.agentName,
                    "instruction": request.instruction
                ]
            )
            showShortSystemResponse("i couldn't find an agent called \(request.agentName).")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "CompanionManager.agentSession",
                    "controller": "CompanionManager",
                    "source": source,
                    "agentName": request.agentName,
                    "error": "No matching agent session"
                ]
            )
            return true
        }

        selectCodexAgentSession(session.id)
        if isAdvancedModeEnabled {
            showCodexHUD()
        } else {
            showAgentDockWindowNearCurrentScreen()
        }

        var extra: [String: String] = [
            "source": source,
            "agentName": request.agentName,
            "sessionID": session.id.uuidString,
            "title": session.title
        ]
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_select.selected",
            fields: extra.merging([
                "instruction": request.instruction
            ]) { current, _ in current }
        )

        if let followUpText = request.followUpText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUpText.isEmpty {
            submitAgentPrompt(followUpText, to: session)
            extra["followUpTextLength"] = "\(followUpText.count)"
            showShortSystemResponse("sent that to \(session.spokenAgentName).")
        } else {
            showShortSystemResponse("switched to \(session.spokenAgentName).")
        }

        markRequestCompleted(
            route: route,
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: extra.merging([
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.selectCodexAgentSession",
                "controller": "CompanionManager"
            ]) { current, _ in current }
        )
        return true
    }

    private func agentSession(matchingSpokenName name: String) -> CodexAgentSession? {
        let needle = Self.normalizedAgentLookupText(name)
        guard !needle.isEmpty else { return nil }

        for dockItem in agentDockItems.reversed() {
            let title = Self.normalizedAgentLookupText(dockItem.title)
            guard title == needle || title.contains(needle) || needle.contains(title) else { continue }
            if let sessionID = dockItem.sessionID,
               let session = codexAgentSessions.first(where: { $0.id == sessionID }) {
                return session
            }
        }

        return codexAgentSessions.reversed().first { session in
            let title = Self.normalizedAgentLookupText(session.title)
            return title == needle || title.contains(needle) || needle.contains(title)
        }
    }

    private func latestSteerableAgentSession() -> CodexAgentSession? {
        if let activeSession = codexAgentSessions.first(where: { $0.id == activeCodexAgentSessionID }),
           Self.isSteerableAgentStatus(activeSession.status),
           activeSession.hasVisibleActivity {
            return activeSession
        }

        if let lastAgentContextSessionID,
           let lastContextSession = codexAgentSessions.first(where: { $0.id == lastAgentContextSessionID }),
           Self.isSteerableAgentStatus(lastContextSession.status),
           lastContextSession.hasVisibleActivity {
            return lastContextSession
        }

        for dockItem in agentDockItems.reversed() {
            guard let sessionID = dockItem.sessionID,
                  let session = codexAgentSessions.first(where: { $0.id == sessionID }),
                  Self.isSteerableAgentStatus(session.status),
                  session.hasVisibleActivity else {
                continue
            }
            return session
        }

        return nil
    }

    /// Detects whether Haiku's response offered to spin up an agent.
    /// Triggers on phrases like "want me to spin up an agent", "should I
    /// start an agent", "i'd need to spin up an agent", or "I can hand that
    /// to an agent". Used to arm the pending-offer slot so the user's next
    /// "yes" / "okay then" can actually launch the agent.
    static func responseOffersAgentSpawn(_ spokenText: String) -> Bool {
        let normalized = spokenText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let offerPatterns = [
            "spin up an agent",
            "spin one up",
            "start an agent",
            "kick off an agent",
            "launch an agent",
            "spawn an agent",
            "have an agent",
            "agent mode",
            "want me to spin",
            "want me to start",
            "should i spin",
            "should i start"
        ]
        if offerPatterns.contains(where: { normalized.contains($0) }) {
            return true
        }

        let handoffPattern = #"\b(?:hand|send|route|pass|delegate|give)\b.{0,48}\b(?:agent|codex)\b"#
        return normalized.range(of: handoffPattern, options: .regularExpression) != nil
    }

    /// If Haiku's last reply offered an agent and the current transcript
    /// is a confirmation, spawn an agent with the remembered instruction.
    /// Returns true when the offer was accepted (caller should not route
    /// further). Falls through (returns false) when there's no pending
    /// offer, the offer expired, or the transcript isn't a confirmation.
    func acceptPendingAgentOfferIfConfirmed(from transcript: String) -> Bool {
        guard let instruction = pendingAgentOfferInstruction,
              let offeredAt = pendingAgentOfferAt,
              Date().timeIntervalSince(offeredAt) <= Self.pendingAgentOfferTTL else {
            // Stale or absent — clear it so a fresh offer can land later.
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
            return false
        }

        guard Self.isAffirmativeConfirmation(transcript) else { return false }

        pendingAgentOfferInstruction = nil
        pendingAgentOfferAt = nil
        let acknowledgement = "on it, starting an agent for that."
        startVoiceAgentTaskPlan(instruction: instruction, acknowledgement: acknowledgement)
        return true
    }

    /// Recognizes a short affirmative response. Only matches when the
    /// entire transcript is a confirmation — we don't want "yes, but
    /// also do X" being treated as a bare yes.
    private static func isAffirmativeConfirmation(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "yes please", "ok", "okay",
            "okay then", "ok then", "alright", "all right", "sure",
            "sure thing", "go", "go ahead", "go for it", "do it",
            "do that", "let's do it", "lets do it", "let's go",
            "spin it up", "spin one up", "fire it up", "fine", "please do",
            "please", "absolutely", "definitely",
            "can you do that", "could you do that", "would you do that",
            "can you do it", "could you do it", "would you do it",
            "please do that", "please do it"
        ]
        return affirmatives.contains(normalized)
    }

    /// Recognizes phrases that clearly mean "speak to the active agent"
    /// rather than "answer this question yourself". Used to gate
    /// `submitContextualAgentFollowUp` so an idle running agent doesn't
    /// silently absorb every subsequent voice turn.
    // MARK: - Speculative pre-fire

    private static func isLikelyAgentFollowUpPhrasing(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return false }

        // Explicit "agent" / "agents" mention always counts as a steer.
        if permissiveAgentInstruction(from: transcript) != nil { return true }

        // Connector words that imply "continue what the agent was doing".
        let connectorPrefixes = [
            "and ", "also ", "now ", "then ", "next ", "after that ",
            "plus ", "as well ", "while you're at it ",
            "keep going", "carry on", "continue", "go on"
        ]
        for prefix in connectorPrefixes where normalized.hasPrefix(prefix) {
            return true
        }

        // Short imperatives like "do that", "yes", "stop", "go".
        let shortImperatives: Set<String> = [
            "do that", "do it", "yes", "yeah", "yep", "ok", "okay",
            "go", "go ahead", "go on", "fine", "sure", "no", "nope", "stop"
        ]
        if shortImperatives.contains(normalized) { return true }

        if isReferentialAgentWorkFollowUp(transcript) { return true }

        return false
    }

    /// Catches follow-ups like "update the form you made earlier" without
    /// routing ordinary questions such as "do you remember what we did earlier"
    /// into Agent Mode.
    private static func isReferentialAgentWorkFollowUp(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return false }

        let referenceSignals = [
            "you did earlier",
            "you made earlier",
            "you created earlier",
            "you built earlier",
            "that you did",
            "that you made",
            "that you created",
            "that you built",
            "from earlier",
            "earlier one",
            "previous one",
            "last one",
            "that file",
            "that page",
            "that form",
            "that site",
            "that app",
            "that project",
            "it again"
        ]
        guard referenceSignals.contains(where: normalized.contains) else { return false }

        let workVerbPattern = #"\b(?:update|change|edit|modify|fix|tweak|adjust|add|remove|delete|make|turn|convert|open|reopen|show|preview|run|test|save|export|publish)\b"#
        return normalized.range(of: workVerbPattern, options: .regularExpression) != nil
    }

    private static func isSteerableAgentStatus(_ status: CodexAgentSessionStatus) -> Bool {
        switch status {
        case .stopped:
            return false
        case .starting, .ready, .running, .failed:
            return true
        }
    }

    // MARK: - Clear-overlays local intent

    /// Returns true when the transcript is a request to clear overlay
    /// annotations (boxes, highlights, cursor markers).
    /// - Parameter hasActiveOverlayAnnotation: pass `hasActiveOverlayAnnotation`
    ///   to gate pronoun-only forms ("clear those") on a live annotation.
    static func isClearOverlayAnnotationsRequest(
        _ transcript: String,
        hasActiveOverlayAnnotation: Bool
    ) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        // Reject if agent-related words appear — keep agent-cancel priority.
        let agentWords = ["agent", "task", "job", "background", "session"]
        if agentWords.contains(where: normalized.contains) { return false }

        let clearVerbs = ["clear", "remove", "hide", "dismiss", "get rid of"]
        let hasVerb = clearVerbs.contains(where: normalized.contains)
        guard hasVerb else { return false }

        let annotationNouns = [
            "rectangle", "rectangles",
            "box", "boxes",
            "highlight", "highlights", "highlighting",
            "overlay", "overlays",
            "drawing", "drawings",
            "annotation", "annotations",
            "marker", "markers"
        ]
        if annotationNouns.contains(where: normalized.contains) {
            return true
        }

        // Pronoun-only form ("clear those", "hide them") — require an active annotation.
        let pronouns = ["those", "that", "them", "these"]
        if pronouns.contains(where: normalized.contains) {
            return hasActiveOverlayAnnotation
        }

        return false
    }

    var hasActiveOverlayAnnotation: Bool {
        detectedElementScreenLocation != nil
            || detectedElementDisplayFrame != nil
            || !cursorOverlayState.visualGuidanceOverlays.isEmpty
            || !cursorOverlayState.externalSecondaryCursors.isEmpty
    }

    func handleClearOverlayAnnotationsRequestIfNeeded(from transcript: String) -> Bool {
        guard Self.isClearOverlayAnnotationsRequest(
            transcript,
            hasActiveOverlayAnnotation: hasActiveOverlayAnnotation
        ) else { return false }

        let timing = activeRequestTiming
        let logFields: [String: Any] = [
            "executor": "local_fast_path",
            "executionMethod": "CompanionManager.clearOverlayAnnotations",
            "controller": "CompanionManager",
            "screenCaptureSkipped": true,
            "modelSkipped": true
        ]
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.clear_overlays",
            timing: timing,
            extra: logFields
        )

        // Clear all active overlay annotations.
        clearDetectedElementLocation()
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        cursorOverlayState.externalSecondaryCursors.removeAll()
        visualGuidanceOverlayClearTasks.values.forEach { $0.cancel() }
        visualGuidanceOverlayClearTasks.removeAll()
        cursorOverlayState.visualGuidanceOverlays.removeAll()
        clearVoiceResponseCaptionAndInteractiveBubble()
        latestVoiceResponseCard = nil

        showShortSystemResponse(
            "cleared.",
            route: "voice.clear_overlays",
            timing: timing,
            executionStartedAt: executionStartedAt,
            extra: logFields
        )
        return true
    }

    func handleAgentCancellationRequestIfNeeded(from transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }

        if Self.isCancelAllAgentTasksRequest(trimmedTranscript) {
            cancelAllAgentTasks()
            return true
        }

        if Self.isCancelCurrentAgentTaskRequest(trimmedTranscript) {
            cancelCurrentAgentTask()
            return true
        }

        return false
    }

    private func cancelAllAgentTasks(reason: String = "agent.cancel_all") {
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.cancel_all",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession"
            ]
        )
        let sessionIDsToCancel = Set(agentDockItems.compactMap(\.sessionID))
        var cancelledCount = 0

        for session in codexAgentSessions {
            guard sessionIDsToCancel.contains(session.id) || Self.isSteerableAgentStatus(session.status) else {
                continue
            }
            cancelAgentTask(sessionID: session.id, removeDockItems: true, reason: reason)
            cancelledCount += 1
        }

        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        pendingAgentVoiceFollowUpSource = nil
        lastAgentContextSessionID = nil

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_tasks.cancelled_all",
            fields: [
                "count": cancelledCount
            ]
        )
        markRequestCompleted(
            route: "agent.cancel_all",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession",
                "cancelledCount": cancelledCount
            ]
        )

        let response: String
        if cancelledCount == 0 {
            response = "there aren't any active agent tasks to cancel."
        } else if cancelledCount == 1 {
            response = "cancelled the agent task."
        } else {
            response = "cancelled all agent tasks."
        }
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: response,
            contextTitle: "Agent tasks"
        )
        showShortSystemResponse(response)
    }

    private func cancelCurrentAgentTask() {
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.cancel_current",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession"
            ]
        )
        guard let session = latestSteerableAgentSession() else {
            showShortSystemResponse("there isn't an active agent task to cancel.")
            markRequestCompleted(
                route: "agent.cancel_current",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "latestSteerableAgentSession",
                    "controller": "CompanionManager",
                    "error": "No active agent task"
                ]
            )
            return
        }

        cancelAgentTask(sessionID: session.id, removeDockItems: true, reason: "agent.cancel_current")
        markRequestCompleted(
            route: "agent.cancel_current",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession",
                "sessionID": session.id.uuidString,
                "title": session.title
            ]
        )
        showShortSystemResponse("cancelled \(session.spokenAgentName).")
    }

    func stopCodexAgentSession(_ sessionID: UUID, reason: String = "agent.stop_button") {
        cancelAgentTask(sessionID: sessionID, removeDockItems: true, reason: reason)
    }

    func cancelAgentTask(sessionID: UUID, removeDockItems: Bool, reason: String = "agent.cancel") {
        cancelPendingAgentDockItemRemoval(for: sessionID)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSession = codexAgentSessions.first(where: { $0.id == sessionID })
        targetSession?.stop(reason: normalizedReason.isEmpty ? nil : normalizedReason)
        completeAgentRequestTimingIfNeeded(
            sessionID: sessionID,
            status: "cancelled",
            extra: [
                "cancelReason": normalizedReason.isEmpty ? "unknown" : normalizedReason
            ]
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.cancelled",
            fields: [
                "sessionID": sessionID.uuidString,
                "title": targetSession?.title ?? "Agent",
                "reason": normalizedReason.isEmpty ? "unknown" : normalizedReason
            ]
        )
        let announcementReason = Self.prettyCancelReason(for: normalizedReason)
        announceAgentCompletionIfNeeded(
            sessionID: sessionID,
            outcome: "cancelled",
            summary: announcementReason,
            cancelReason: normalizedReason
        )
        if removeDockItems {
            scheduleAgentDockItemRemoval(for: sessionID)
        }
        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
        }
        if lastAgentContextSessionID == sessionID {
            lastAgentContextSessionID = nil
        }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleStatusSync()
    }

    func startExplicitAgentTaskIfRequested(from transcript: String) -> Bool {
        if let newTaskInstruction = Self.explicitNewTaskInstruction(from: transcript) {
            guard !newTaskInstruction.isEmpty else {
                showShortSystemResponse("what should the new task be?")
                return true
            }

            startVoiceAgentTaskPlan(instruction: newTaskInstruction)
            return true
        }

        if Self.isIncompleteExplicitNewTaskRequest(from: transcript) {
            showShortSystemResponse("what should the new task be?")
            return true
        }

        if let taskCreationInstruction = Self.agentTaskCreationInstruction(from: transcript) {
            guard !taskCreationInstruction.isEmpty else {
                showShortSystemResponse("what should the agent do?")
                return true
            }

            if let typeRequest = Self.nativeTypeRequest(from: taskCreationInstruction) {
                typeTextUsingSelectedComputerUse(typeRequest)
                return true
            }

            if let keyPressRequest = Self.nativeKeyPressRequest(from: taskCreationInstruction) {
                pressKeyUsingSelectedComputerUse(keyPressRequest)
                return true
            }

            if let clickRequest = Self.nativeClickRequest(from: taskCreationInstruction) {
                clickUsingSelectedComputerUse(clickRequest)
                return true
            }

            if let systemVolumeAction = Self.systemVolumeControlAction(from: taskCreationInstruction) {
                runSystemVolumeControl(systemVolumeAction, instruction: taskCreationInstruction)
                return true
            }

            if let folderRequest = folderOpenRequest(from: taskCreationInstruction),
               Self.shouldInlineDirectFolderOpenFromAgentInstruction(taskCreationInstruction) {
                openRequestedFolder(folderRequest)
                return true
            }

            print("OpenClicky agent task creation request detected: \(taskCreationInstruction)")
            startVoiceAgentTaskPlan(instruction: taskCreationInstruction)
            return true
        }

        if Self.isIncompleteAgentTaskCreationRequest(from: transcript) {
            showShortSystemResponse("what should the agent do?")
            return true
        }

        let explicitInstructionFromCliky = Self.clickyAgentInstruction(from: transcript)
        let permissiveInstruction = explicitInstructionFromCliky == nil
            ? Self.permissiveAgentInstruction(from: transcript)
            : nil

        guard let explicitInstruction = explicitInstructionFromCliky ?? permissiveInstruction else {
            return false
        }

        guard !explicitInstruction.isEmpty else {
            print("OpenClicky agent trigger detected without an instruction.")
            showShortSystemResponse("what should the agent do?")
            return true
        }

        var instruction = SpokenText.normalizedAgentTaskInstruction(from: explicitInstruction)
        if Self.isReferentialAgentInstruction(instruction) {
            guard let resolvedInstruction = referentialAgentInstructionContext(excluding: transcript) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.referential_instruction_unresolved",
                    fields: [
                        "transcript": transcript,
                        "explicitInstruction": explicitInstruction,
                        "requestID": activeRequestTiming?.requestID ?? "none"
                    ]
                )
                showShortSystemResponse("what should the agent do?")
                return true
            }

            instruction = resolvedInstruction
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.referential_instruction_resolved",
                fields: [
                    "transcript": transcript,
                    "explicitInstruction": explicitInstruction,
                    "resolvedInstruction": instruction,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
        }
        if let typeRequest = Self.nativeTypeRequest(from: instruction) {
            typeTextUsingSelectedComputerUse(typeRequest)
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: instruction) {
            pressKeyUsingSelectedComputerUse(keyPressRequest)
            return true
        }

        if let clickRequest = Self.nativeClickRequest(from: instruction) {
            clickUsingSelectedComputerUse(clickRequest)
            return true
        }

        if let systemVolumeAction = Self.systemVolumeControlAction(from: instruction) {
            runSystemVolumeControl(systemVolumeAction, instruction: instruction)
            return true
        }

        if let folderRequest = folderOpenRequest(from: instruction),
           Self.shouldInlineDirectFolderOpenFromAgentInstruction(instruction) {
            openRequestedFolder(folderRequest)
            return true
        }

        if let compositeRequest = Self.compositeAppActionRequest(from: instruction) {
            startVoiceAgentTask(
                instruction: Self.compositeAppActionAgentInstruction(from: compositeRequest),
                acknowledgement: "i’ll do the app action, not just open the app.",
                route: "agent.composite_app_action",
                voiceContextUserTranscript: instruction
            )
            return true
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: instruction) {
            _ = openRequestedApplication(appOpenRequest)
            return true
        }
        if Self.isIncompleteLocalAppOpenRequest(from: instruction) {
            showShortSystemResponse("what app should I open?")
            return true
        }

        print("OpenClicky agent task detected; starting agent task: \(instruction)")
        startVoiceAgentTaskPlan(instruction: instruction)
        return true
    }

    private func referentialAgentInstructionContext(excluding transcript: String) -> String? {
        let now = Date()
        if let pendingInstruction = pendingAgentOfferInstruction,
           let offeredAt = pendingAgentOfferAt,
           now.timeIntervalSince(offeredAt) <= Self.pendingAgentOfferTTL {
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
            return pendingInstruction
        }

        if let offeredAt = pendingAgentOfferAt,
           now.timeIntervalSince(offeredAt) > Self.pendingAgentOfferTTL {
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
        }

        let candidates: [(String?, Date?)] = [
            (lastVoiceUserTranscript, lastVoiceUserTranscriptAt),
            (previousVoiceUserTranscript, previousVoiceUserTranscriptAt)
        ]
        for (candidate, candidateAt) in candidates {
            guard let candidate,
                  let candidateAt,
                  now.timeIntervalSince(candidateAt) <= Self.pendingAgentOfferTTL else {
                continue
            }
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidate.isEmpty,
                  SpokenText.normalizedSpokenCommandText(trimmedCandidate) != SpokenText.normalizedSpokenCommandText(transcript),
                  !Self.isReferentialAgentInstruction(trimmedCandidate) else {
                continue
            }
            return trimmedCandidate
        }

        return nil
    }

    static func isCancelAllAgentTasksRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        if isAgentDelegationRequest(normalizedTranscript) {
            return false
        }
        let phrases = [
            "cancel all tasks",
            "cancel all task",
            "cancel all agents",
            "cancel all agent tasks",
            "stop all tasks",
            "stop all agents",
            "stop all agent tasks",
            "kill all tasks",
            "kill all agents",
            "dismiss all tasks",
            "dismiss all agents",
            "clear all tasks",
            "clear all agents",
            "cancel everything",
            "stop everything",
            "kill everything"
        ]
        return phrases.contains { normalizedTranscript.contains($0) }
    }

    static func isCancelCurrentAgentTaskRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        if isAgentDelegationRequest(normalizedTranscript) {
            return false
        }
        let phrases = [
            "cancel that",
            "cancel this",
            "cancel it",
            "cancel task",
            "cancel the task",
            "cancel current task",
            "cancel current agent",
            "cancel the agent",
            "cancel that agent",
            "stop that",
            "stop this",
            "stop it",
            "stop task",
            "stop the task",
            "stop current task",
            "stop current agent",
            "stop the agent",
            "kill that",
            "kill this",
            "kill it",
            "kill task",
            "kill the task",
            "done with that",
            "done with this"
        ]
        if phrases.contains(normalizedTranscript) {
            return true
        }

        let explicitAgentStopPattern = #"\b(?:cancel|stop|kill|dismiss)\b.{0,28}\b(?:agent|task|codex|background\s+task)\b"#
        return normalizedTranscript.range(of: explicitAgentStopPattern, options: .regularExpression) != nil
    }

    private static func isAgentDelegationRequest(_ normalizedTranscript: String) -> Bool {
        let delegationPhrases = [
            "get another agent",
            "start another agent",
            "spin up another agent",
            "launch another agent",
            "get an agent",
            "start an agent",
            "spin up an agent",
            "launch an agent",
            "have an agent",
            "ask an agent",
            "new agent",
            "another agent to",
            "agent to look",
            "agent look at",
            "agent to check",
            "agent to investigate",
            "agent to fix"
        ]
        return delegationPhrases.contains { normalizedTranscript.contains($0) }
    }

    private static func explicitNewTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task\s*[:,-]?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch|set\s+off)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task\s*(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*set\s+(?:an?\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+(?:off|going)\s+(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?\s*[:,-]?\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    private static func isExplicitNewTaskRequest(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil || isIncompleteExplicitNewTaskRequest(from: transcript)
    }

    private static func isIncompleteExplicitNewTaskRequest(from transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch|set\s+off)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task[\s\.\!\?]*$"#,
            #"(?i)^\s*set\s+(?:an?\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+(?:off|going)[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil {
                return true
            }
        }

        return false
    }

    static func quickLocalVoiceResponseText(for transcript: String) -> String? {
        let candidate = normalizedQuickLocalVoiceResponseCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let acknowledgementChecks = [
            "yes", "yeah", "yep", "no", "nope", "ok", "okay",
            "ok then", "okay then",
            "alright", "all right", "yeah alright", "yeah all right",
            "sounds good", "fair enough"
        ]
        if acknowledgementChecks.contains(candidate) {
            return "okay."
        }

        let hearingChecks = [
            "can you hear me",
            "can you hear us",
            "do you hear me",
            "do you hear us",
            "are you hearing me",
            "are you hearing us"
        ]
        if hearingChecks.contains(candidate) {
            return "yes, i can hear you."
        }

        let availabilityChecks = [
            "are you there",
            "are you still there",
            "are you listening",
            "are you awake",
            "you there",
            "hello",
            "hello there",
            "hi"
        ]
        if availabilityChecks.contains(candidate) {
            return "i'm here."
        }

        let connectionChecks = [
            "are you connected",
            "are we connected",
            "am i connected",
            "are you online",
            "are you working",
            "checking connection",
            "checking connection 123",
            "checking connection one two three",
            "connection check",
            "connection check 123",
            "connection check one two three"
        ]
        if connectionChecks.contains(candidate) {
            return "connection is working."
        }

        let capabilityChecks = [
            "what can you do",
            "what can you do for me",
            "what do you do",
            "what are you able to do",
            "what can openclicky do",
            "what can clicky do"
        ]
        if capabilityChecks.contains(candidate) {
            return "i can answer quick questions, look at your screen when needed, open apps and control your Mac, and hand bigger jobs to Agent Mode."
        }

        let voiceControlChecks = [
            "checking voice",
            "checking voice control",
            "just checking voice",
            "just checking voice control",
            "test test",
            "test 123",
            "test one two three",
            "testing",
            "testing 123",
            "testing one two three",
            "testing testing",
            "testing testing 123",
            "testing testing testing",
            "testing voice",
            "testing voice control",
            "testing out voice",
            "testing out voice control",
            "i am testing voice control",
            "i am testing out voice control",
            "im testing voice control",
            "im testing out voice control"
        ]
        if voiceControlChecks.contains(candidate) {
            return "voice control is working."
        }

        let slowResponseChecks = [
            "nothing is happening",
            "nothing happening",
            "why is nothing happening"
        ]
        if slowResponseChecks.contains(candidate) {
            return "i'm here. that last response was taking longer than expected."
        }

        return nil
    }

    private static func normalizedQuickLocalVoiceResponseCandidate(from transcript: String) -> String {
        var candidate = SpokenText.normalizedSpokenCommandText(transcript)
        let fillerPrefixes = ["hey", "ok", "okay", "right", "so"]
        let invocationPrefixes = [
            "learning buddy",
            "cursor buddy",
            "leaning buddy",
            "open clicky",
            "openclicky",
            "clicky",
            "buddy"
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for prefix in fillerPrefixes + invocationPrefixes {
                if candidate == prefix {
                    return ""
                }
                if candidate.hasPrefix(prefix + " ") {
                    candidate.removeFirst(prefix.count)
                    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    didStripPrefix = true
                }
            }
        }

        return candidate
    }

    func handleQuickLocalVoiceResponseIfNeeded(from transcript: String) -> Bool {
        guard let responseText = Self.quickLocalVoiceResponseText(for: transcript) else { return false }

        let timing = activeRequestTiming
        let logFields: [String: Any] = [
            "executor": "local_fast_path",
            "executionMethod": "CompanionManager.quickLocalVoiceResponseText",
            "controller": "CompanionManager",
            "screenCaptureSkipped": true,
            "modelSkipped": true,
            "transcriptLength": transcript.count,
            "spokenTextLength": responseText.count
        ]
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.quick_local_response",
            timing: timing,
            extra: logFields
        )

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: responseText,
            contextTitle: transcript
        )
        showShortSystemResponse(
            responseText,
            route: "voice.quick_local_response",
            timing: timing,
            executionStartedAt: executionStartedAt,
            extra: logFields
        )
        return true
    }

    func handleAgentStatusQuestionIfNeeded(from transcript: String) -> Bool {
        guard Self.isAgentStatusQuestion(transcript) else { return false }
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.status",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "agentStatusSpokenSummary",
                "controller": "CompanionManager"
            ]
        )

        let summary = agentStatusSpokenSummary()
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: summary,
            contextTitle: "Agent status"
        )
        if codexAgentSessions.contains(where: { $0.hasVisibleActivity && !archivedSessionIDs.contains($0.id) }) {
            ensureCursorOverlayVisibleForAgentTask()
            showAgentDockWindowNearCurrentScreen()
        }
        showShortSystemResponse(summary)
        markRequestCompleted(
            route: "agent.status",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "agentStatusSpokenSummary",
                "controller": "CompanionManager",
                "visibleAgentCount": codexAgentSessions.filter { session in
                    session.hasVisibleActivity && !archivedSessionIDs.contains(session.id)
                }.count
            ]
        )
        return true
    }

    private func agentStatusSpokenSummary() -> String {
        let visibleSessions = codexAgentSessions.filter { session in
            session.hasVisibleActivity && !archivedSessionIDs.contains(session.id)
        }
        guard !visibleSessions.isEmpty else {
            return "no agents are running yet."
        }

        let runningCount = visibleSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }.count
        let failedCount = visibleSessions.filter { session in
            if case .failed = session.status { return true }
            return false
        }.count
        let readyCount = visibleSessions.filter { session in
            if case .ready = session.status { return true }
            return false
        }.count

        let headline: String
        if runningCount > 0 {
            headline = "\(Self.spokenCount(runningCount, singular: "agent", plural: "agents")) running"
        } else if failedCount > 0 {
            headline = "\(Self.spokenCount(failedCount, singular: "agent", plural: "agents")) needing attention"
        } else {
            headline = "\(Self.spokenCount(readyCount, singular: "agent", plural: "agents")) ready"
        }

        let details = visibleSessions
            .suffix(3)
            .map(\.statusSummaryLine)
            .joined(separator: " ")

        return "you have \(Self.spokenCount(visibleSessions.count, singular: "agent", plural: "agents")): \(headline). \(details)"
    }

    private func updateAgentProgressNarration() {
        let now = Date()
        if let lastAgentProgressNarrationAt,
           now.timeIntervalSince(lastAgentProgressNarrationAt) < 30 {
            return
        }

        speakAgentProgressUpdateIfAppropriate(now: now)
    }

    private func speakAgentProgressUpdateIfAppropriate(now: Date = Date()) {
        // Default OFF: users asked to stop automatic "working on it"
        // style voice updates while agents are still in flight.
        let progressVoiceEnabled = UserDefaults.standard.object(forKey: Self.agentProgressVoiceUpdatesDefaultsKey) as? Bool ?? false
        guard progressVoiceEnabled else { return }

        let runningSessions = codexAgentSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }

        guard !runningSessions.isEmpty else { return }
        guard voiceState == .idle else { return }

        // Only narrate sessions that have substantively new activity since
        // the last time we spoke about them. No filler — "we're working"
        // / "we're starting" no longer counts. If nothing meaningful has
        // changed, stay silent. This replaces the old behavior of
        // speaking "the agent says we're working" every 30 seconds.
        let updates: [(session: CodexAgentSession, phrase: String, signature: String)] =
            runningSessions.compactMap { session in
                guard let phrase = Self.agentProgressPhrase(for: session) else { return nil }
                let signature = "\(session.id.uuidString)|\(phrase)"
                if lastAgentProgressNarrationSignatures[session.id] == phrase {
                    return nil
                }
                return (session, phrase, signature)
            }

        guard !updates.isEmpty else { return }

        let updateText: String
        if updates.count == 1, let only = updates.first {
            updateText = "\(only.session.spokenAgentSentenceName) says \(only.phrase)."
        } else {
            let details = updates
                .prefix(3)
                .map { "\($0.session.spokenAgentSentenceName) says \($0.phrase)" }
                .joined(separator: ". ")
            let remainingCount = updates.count - min(updates.count, 3)
            if remainingCount > 0 {
                updateText = "\(details). \(remainingCount) more running."
            } else {
                updateText = details + "."
            }
        }

        for update in updates {
            lastAgentProgressNarrationSignatures[update.session.id] = update.phrase
        }
        lastAgentProgressNarrationAt = now
        showShortSystemResponse(updateText)
    }

    /// Build the spoken phrase for an in-flight agent. Returns `nil` when
    /// there is nothing substantive to say — never returns filler like
    /// "we're working" or "we're starting", because the narration policy
    /// is now silence-by-default.
    private static func agentProgressPhrase(for session: CodexAgentSession) -> String? {
        guard let activity = session.latestActivitySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !activity.isEmpty else {
            return nil
        }

        // Map a few well-known activity shapes to natural-sounding phrases.
        // For anything else, just speak the raw activity verbatim.
        if activity.contains("matching files") || activity.contains("looking for") {
            return "we're checking the files"
        }
        if activity.contains("focusing") || activity.contains("showing") {
            return "we're opening what we found"
        }
        if activity.contains("checking the work") {
            return "we're checking the work"
        }
        // Suppress the "we're working" / "still working" filler — we want
        // silence when nothing concrete has happened. If the activity is
        // genuinely just a "working" word with no detail, return nil.
        if activity == "working" || activity == "still working"
            || activity == "running" || activity == "in progress" {
            return nil
        }
        return "we're \(activity)"
    }

    private static func isAgentStatusQuestion(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)

        let mentionsAgent = normalizedTranscript.contains("agent") || normalizedTranscript.contains("agents") || normalizedTranscript.contains("codex")
        guard mentionsAgent else { return false }

        let statusPatterns = [
            #"\b(?:agent|agents|codex)\s+(?:status|progress)\b"#,
            #"\b(?:status|progress)\s+(?:of|on|for)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\b(?:how\s+(?:are|is|s))\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\bwhat\s+(?:are|is|s)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+(?:doing|up\s+to|working\s+on)\b"#,
            #"\bwhat\s+(?:is|s)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+status\b"#,
            #"\bwhat\s+(?:is|s)\s+(?:the\s+)?(?:status|progress)\s+(?:of|on|for)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\b(?:is|are)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+(?:still\s+)?(?:running|finished|done|working)\b"#,
            #"\b(?:agent|agents|codex)\s+(?:still\s+)?(?:doing|running|finished|done|working)\b"#,
            #"\b(?:agent|agents|codex)\s+up\s+to\b"#,
            #"\b(?:your|the)\s+(?:agent|agents|codex)\s+(?:status|progress)\b"#
        ]

        return statusPatterns.contains { pattern in
            normalizedTranscript.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func spokenCount(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "one \(singular)" : "\(count) \(plural)"
    }

    private static func alphanumericTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var currentStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if currentStart == nil {
                    currentStart = index
                }
            } else if let start = currentStart {
                ranges.append(start..<index)
                currentStart = nil
            }
            index = text.index(after: index)
        }

        if let start = currentStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    private static func clickyAgentInstruction(from transcript: String) -> String? {
        struct TranscriptToken {
            let normalizedText: String
            let originalRange: Range<String.Index>
        }

        let foldedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = alphanumericTokenRanges(in: foldedTranscript).map { range in
            TranscriptToken(
                normalizedText: String(foldedTranscript[range]).lowercased(),
                originalRange: range
            )
        }

        guard !tokens.isEmpty else { return nil }

        for tokenIndex in tokens.indices {
            var scanningIndex = tokenIndex
            var sawHeyPrefix = false

            if tokens[scanningIndex].normalizedText == "hey" {
                sawHeyPrefix = true
                scanningIndex += 1
                guard scanningIndex < tokens.count else { continue }
            }

            if tokens[scanningIndex].normalizedText == "open" {
                scanningIndex += 1
                guard scanningIndex < tokens.count else { continue }
            }

            if tokens[scanningIndex].normalizedText == "agent", sawHeyPrefix {
                let rawInstruction = String(transcript[tokens[scanningIndex].originalRange.upperBound...])
                let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
                return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Apple Speech can also insert "the" into the wake phrase:
            // "Hey, the agent ..." should be treated like "Hey agent ...".
            if tokens[scanningIndex].normalizedText == "the", sawHeyPrefix {
                let agentTokenIndex = scanningIndex + 1
                if agentTokenIndex < tokens.count,
                   tokens[agentTokenIndex].normalizedText == "agent" {
                    let rawInstruction = String(transcript[tokens[agentTokenIndex].originalRange.upperBound...])
                    let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
                    return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Apple Speech often hears "Clicky agent" as "click the agent".
            // Treat that exact token sequence as the product wake phrase so
            // long-form live partials can still be deferred to Agent Mode.
            if tokens[scanningIndex].normalizedText == "click" {
                let theTokenIndex = scanningIndex + 1
                let agentTokenIndex = scanningIndex + 2
                if theTokenIndex < tokens.count,
                   agentTokenIndex < tokens.count,
                   tokens[theTokenIndex].normalizedText == "the",
                   tokens[agentTokenIndex].normalizedText == "agent" {
                    let rawInstruction = String(transcript[tokens[agentTokenIndex].originalRange.upperBound...])
                    let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
                    return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            guard isClickyInvocationToken(tokens[scanningIndex].normalizedText) else { continue }

            let agentTokenIndex = scanningIndex + 1
            guard agentTokenIndex < tokens.count else { continue }
            guard tokens[agentTokenIndex].normalizedText == "agent" else { continue }

            let rawInstruction = String(transcript[tokens[agentTokenIndex].originalRange.upperBound...])
            let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
            return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func isClickyInvocationToken(_ normalizedText: String) -> Bool {
        switch normalizedText {
        case "clicky", "klicky", "openclicky", "cookie", "quick":
            return true
        default:
            return false
        }
    }

    /// Permissive fallback: if the user says anything containing the word
    /// "agent" (e.g. "ask an agent to...", "have an agent...", "tell the agent..."),
    /// route to delegation. Cancellation/status/selection branches run first in
    /// `handleFinalVoiceTranscript`, so this only triggers for actual task
    /// creation. Returns nil if "agent" appears only as part of another word
    /// like "agency", or if the remaining instruction would be empty.
    static func permissiveAgentInstruction(from transcript: String) -> String? {
        let folded = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokenRanges = alphanumericTokenRanges(in: folded)
        guard !tokenRanges.isEmpty else { return nil }

        // Prefer the last exact "agent" / "agents" token, but fall back to
        // earlier ones. Dictation can append trailing phrases like "agent
        // work"; using only the last token can hide the real delegation.
        var agentTokenRanges: [Range<String.Index>] = []
        for range in tokenRanges {
            let token = String(folded[range]).lowercased()
            if token == "agent" || token == "agents" {
                agentTokenRanges.append(range)
            }
        }
        guard !agentTokenRanges.isEmpty else { return nil }

        for agentTokenRange in agentTokenRanges.reversed() {
            if let instruction = permissiveAgentInstructionCandidate(
                from: transcript,
                folded: folded,
                agentTokenRange: agentTokenRange
            ) {
                return instruction
            }
        }

        return nil
    }

    private static func permissiveAgentInstructionCandidate(
        from transcript: String,
        folded: String,
        agentTokenRange: Range<String.Index>
    ) -> String? {
        let afterAgent = String(transcript[agentTokenRange.upperBound...])
        let cleaned = afterAgent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading connector
        // ("ask an agent to X" -> "X", "task an agent with X" -> "X").
        let lowercased = cleaned.lowercased()
        let connectors = ["to ", "for ", "with ", "that ", "which ", "who ", "and ", "please ", "could you ", "can you "]
        var instruction = cleaned
        var strippedLeadingConnector = false
        for connector in connectors where lowercased.hasPrefix(connector) {
            instruction = String(cleaned.dropFirst(connector.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            strippedLeadingConnector = true
            break
        }

        guard !instruction.isEmpty else { return nil }
        let beforeAgent = String(folded[..<agentTokenRange.lowerBound])
        let normalizedBeforeAgent = SpokenText.normalizedSpokenCommandText(beforeAgent)
        let normalizedInstruction = SpokenText.normalizedSpokenCommandText(instruction)

        let delegationCuePattern = #"\b(?:ask|tell|have|get|task|use|start|create|spin\s+up|spawn|run|launch|kick\s+off|set\s+up|send|route|hand|pass)\b"#
        let hasDelegationCueBefore = normalizedBeforeAgent.range(
            of: delegationCuePattern,
            options: .regularExpression
        ) != nil

        let afterAgentImperativePattern = #"^(?:find|search|look|inspect|review|open|create|make|build|update|fix|change|edit|check|run|test|summarize|analyse|analyze|clean|audit)\b"#
        let hasImperativeAfterAgent = normalizedInstruction.range(
            of: afterAgentImperativePattern,
            options: .regularExpression
        ) != nil
        let hasAgentTaskShape = hasDelegationCueBefore
            || strippedLeadingConnector
            || hasImperativeAfterAgent
            || isLikelyAgentToolWorkInstruction(instruction)
        guard hasAgentTaskShape else { return nil }

        let beforeTokens = normalizedBeforeAgent.split(separator: " ")
        if let lastBeforeAgent = beforeTokens.last,
           (lastBeforeAgent == "ai" || lastBeforeAgent == "openai"),
           !hasDelegationCueBefore,
           !strippedLeadingConnector {
            return nil
        }

        return instruction
    }

    private static func shouldInlineDirectFolderOpenFromAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        guard !normalized.isEmpty else { return false }

        let agentWorkSignals = [
            "look at",
            "take a look",
            "review",
            "inspect",
            "audit",
            "go through",
            "check",
            "improve",
            "improvement",
            "recommend",
            "make any",
            "find",
            "search",
            "read",
            "analyze",
            "analyse"
        ]
        if agentWorkSignals.contains(where: { normalized.contains($0) }) {
            return false
        }

        let directFolderPrefixes = [
            "open ",
            "show ",
            "reveal ",
            "bring up ",
            "pull up ",
            "go into ",
            "go in ",
            "go to ",
            "navigate to ",
            "switch to ",
            "inside "
        ]
        return directFolderPrefixes.contains { normalized.hasPrefix($0) }
    }

    static func isReferentialAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        guard !normalized.isEmpty else { return false }

        let referentialInstructions: Set<String> = [
            "that",
            "it",
            "this",
            "do that",
            "do it",
            "do this",
            "on it",
            "get on it",
            "take care of it",
            "that one",
            "the thing",
            "the task",
            "the previous thing",
            "the previous task"
        ]
        return referentialInstructions.contains(normalized)
    }

    static func agentTaskCreationInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        if let diagnosticInstruction = diagnosticPasteAgentInstruction(from: candidate) {
            return diagnosticInstruction
        }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?set\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:off|going)\s+(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:the\s+)?(?:agent|agenty|codex)\s+(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)?\s*(?:task|job|session)?\s*(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get|task)\s+(?:an?\s+|the\s+)?(?:agent|agenty|codex)\s+(?:to|for|with)\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:agent|agenty|codex)\s+(?:with|for)\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else { continue }
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        if let noisyInstruction = noisyAgentTaskCreationInstruction(from: candidate) {
            return noisyInstruction
        }

        return misheardQuestionAgentInstruction(from: candidate)
    }

    private static func diagnosticPasteAgentInstruction(from candidate: String) -> String? {
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard normalized.hasPrefix("see issue here")
            || normalized.hasPrefix("see the issue here")
            || normalized.hasPrefix("look at this")
            || normalized.hasPrefix("look at these")
            || normalized.hasPrefix("fix this")
            || normalized.hasPrefix("what is this")
            || normalized.hasPrefix("whats this")
            || normalized.hasPrefix("what's this")
        else {
            return nil
        }

        let rawLogSignals = [
            "[OpenClickyLog]",
            "openclicky.",
            "NSXPCDecoder",
            "NSXPCInterface",
            "NSXPCConnection",
            "ViewBridge",
            "NSViewBridgeError",
            "unifiedReasons",
            "Unable to obtain a task name port right",
            "nw_protocol_instance",
            "agent_sdk_query",
            "_sdk_query",
            "Bridge SDK Message",
            "kDragIPC",
            "Reentrant message",
            "stack trace",
            "traceback",
            "exception",
            "error domain="
        ]

        guard candidate.count > 240 || rawLogSignals.contains(where: { candidate.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }

        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func misheardQuestionAgentInstruction(from candidate: String) -> String? {
        let pattern = #"(?i)^\s*(?:question|agent\s+question)\s*[:,-]?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: range),
              let instructionRange = Range(match.range(at: 1), in: candidate) else {
            return nil
        }

        let instruction = SpokenText.normalizedAgentTaskInstruction(
            from: SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
        )
        guard !instruction.isEmpty,
              !isAgentTaskPlaceholderInstruction(instruction),
              isLikelyAgentToolWorkInstruction(instruction) else {
            return nil
        }
        return instruction
    }

    private static func isLikelyAgentToolWorkInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        let toolWorkSignals = [
            "github",
            "issue",
            "issues",
            "pull request",
            "pr",
            "desktop",
            "download",
            "downloads",
            "document",
            "documents",
            "folder",
            "folders",
            "file",
            "files",
            "code",
            "repo",
            "repository",
            "diff",
            "changes",
            "log",
            "logs",
            "conversation logs",
            "clean up",
            "cleanup",
            "review",
            "inspect",
            "audit",
            "look at",
            "take a look",
            "research",
            "summarize",
            "summary",
            "voice",
            "realtime",
            "computer use",
            "tool",
            "tools",
            "tooling",
            "model",
            "models",
            "routing",
            "background",
            "agent mode",
            "slider",
            "find",
            "search"
        ]
        return toolWorkSignals.contains { normalized.contains($0) }
    }

    private static func noisyAgentTaskCreationInstruction(from candidate: String) -> String? {
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }

        let patterns = [
            #"(?i)(?:^|[\s,;:—–\-]+)(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get)\s+(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#,
            #"(?i)(?:^|[\s,;:—–\-]+)(?:send|route|hand|pass)\s+(?:this|that|it|the\s+(?:task|request|context|screen|file|code|change|changes))\s+(?:over\s+)?to\s+(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?(?:\s+to)?\s+(.+?)\s*$"#,
            #"(?i)^\s*[\.…,;:—–\-]*\s*(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else { continue }
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    private static func isMetaAgentRoutingQuestion(_ candidate: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        let prefixes = [
            "how do i ask",
            "how can i ask",
            "how should i ask",
            "what do i say",
            "what should i say",
            "why did",
            "why didnt",
            "why didn t",
            "why didn't",
            "why doesnt",
            "why doesn t",
            "why doesn't",
            "when i asked",
            "when i ask"
        ]
        return prefixes.contains { normalized.hasPrefix($0) }
    }

    private static func isIncompleteAgentTaskCreationRequest(from transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?set\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?\s+(?:off|going)[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:the\s+)?(?:agent|codex)\s+(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)?\s*(?:task|job|session)?[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get)\s+(?:an?\s+|the\s+)?(?:agent|codex)(?:\s+to)?[\s\.\!\?]*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil {
                return true
            }
        }

        return false
    }

    private static func isAgentTaskPlaceholderInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["agent", "task", "job", "session", "agent task", "agent job", "codex task"].contains(normalized)
    }

    private static func agentSelectionRequest(from transcript: String) -> OpenClickyAgentSelectionRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let typedFollowUpPatterns = [
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+(?:the\s+)?(.+?)\s+agent\s+and\s+(?:type|write|enter)\s+(.+?)(?:\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?)?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+(?:agent\s+)?(.+?)\s+and\s+(?:type|write|enter)\s+(.+?)(?:\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?)?[\.\!\?]*\s*$"#
        ]

        for pattern in typedFollowUpPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let nameRange = Range(match.range(at: 1), in: candidate),
                  let textRange = Range(match.range(at: 2), in: candidate) else {
                continue
            }

            let agentName = cleanedAgentSelectionName(String(candidate[nameRange]))
            let followUpText = cleanedAgentSelectionFollowUp(String(candidate[textRange]))
            guard !agentName.isEmpty, !followUpText.isEmpty else { continue }
            return OpenClickyAgentSelectionRequest(
                agentName: agentName,
                followUpText: followUpText,
                instruction: candidate
            )
        }

        let selectionPatterns = [
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+(?:the\s+)?(.+?)\s+agent[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+agent\s+(.+?)[\.\!\?]*\s*$"#
        ]

        for pattern in selectionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let nameRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let agentName = cleanedAgentSelectionName(String(candidate[nameRange]))
            guard !agentName.isEmpty else { continue }
            return OpenClickyAgentSelectionRequest(
                agentName: agentName,
                followUpText: nil,
                instruction: candidate
            )
        }

        return nil
    }

    private static func cleanedAgentSelectionName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        name = stripMatchingQuotes(from: name)
        name = name.replacingOccurrences(
            of: #"(?i)^(?:the|a|an)\s+"#,
            with: "",
            options: .regularExpression
        )
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        return isAgentTaskPlaceholderInstruction(name) ? "" : name
    }

    private static func cleanedAgentSelectionFollowUp(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        text = text.replacingOccurrences(
            of: #"(?i)\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?$"#,
            with: "",
            options: .regularExpression
        )
        text = stripMatchingQuotes(from: text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    private static func normalizedAgentLookupText(_ value: String) -> String {
        SpokenText.normalizedSpokenCommandText(value)
            .replacingOccurrences(of: #"\b(?:agent|task|session)\b"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func directComputerUseFingerprint(kind: String, value: String) -> String {
        let normalizedValue = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(kind):\(normalizedValue)"
    }

    struct SmartAgentRouteDecision {
        let instruction: String
        let acknowledgement: String
        let reason: String
        let confidence: Double
    }

    private static func parallelAgentInstructions(from instruction: String) -> [String] {
        let cleanedInstruction = SpokenText.cleanedAgentTaskInstruction(instruction)
        guard !cleanedInstruction.isEmpty else { return [] }
        guard logEvidenceAnalysisInstruction(from: cleanedInstruction) == nil,
              !isRawTransportDiagnosticEvent(cleanedInstruction) else {
            return [cleanedInstruction]
        }
        guard shouldSplitAgentInstruction(cleanedInstruction) else { return [cleanedInstruction] }

        let pieces = splitAgentInstructionClauses(cleanedInstruction)
            .map(SpokenText.cleanedAgentTaskInstruction)
            .filter { !$0.isEmpty && !isAgentTaskPlaceholderInstruction($0) }

        guard pieces.count >= 2 else { return [cleanedInstruction] }
        guard pieces.allSatisfy({ isLikelySpecificAgentInstruction($0) || hasAgentWorkVerbAndArtifact($0) }) else {
            return [cleanedInstruction]
        }

        return Array(pieces.prefix(4))
    }

    private static func shouldSplitAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        let explicitSplitPattern = #"\b(?:multiple|several|separate|parallel|independent)\s+(?:background\s+)?(?:agents?|tasks?|workstreams?)\b|\bsplit\b.{0,48}\b(?:agents?|tasks?|workstreams?)\b|\b(?:agents?|tasks?)\b.{0,48}\b(?:separately|in\s+parallel|side\s+by\s+side)\b"#
        if normalized.range(of: explicitSplitPattern, options: .regularExpression) != nil {
            return true
        }

        let enumeratedPattern = #"(?:^|[\n;,.]\s*)(?:first|second|third|fourth|1[.)]|2[.)]|3[.)]|4[.)])\b"#
        return instruction.range(of: enumeratedPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func splitAgentInstructionClauses(_ instruction: String) -> [String] {
        let markerPattern = #"(?i)(?:^|[\n;]\s+|\s+)(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|1[.)]|2[.)]|3[.)]|4[.)]|also|separately|another\s+agent\s+(?:to|for)|and\s+another\s+(?:agent\s+)?(?:to|for))[:,]?\s+"#
        let markerRegex = try? NSRegularExpression(pattern: markerPattern)
        let fullRange = NSRange(instruction.startIndex..<instruction.endIndex, in: instruction)
        let matches = markerRegex?.matches(in: instruction, range: fullRange) ?? []
        guard matches.count >= 2 else {
            return instruction
                .components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        var pieces: [String] = []
        for (index, match) in matches.enumerated() {
            guard let start = Range(match.range, in: instruction)?.upperBound else { continue }
            let end: String.Index
            if index + 1 < matches.count,
               let nextStart = Range(matches[index + 1].range, in: instruction)?.lowerBound {
                end = nextStart
            } else {
                end = instruction.endIndex
            }
            pieces.append(String(instruction[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pieces
    }

    static func shouldDeferLiveComputerUseForAgentRoute(_ transcript: String) -> Bool {
        isAgentRoutingCandidate(transcript)
    }

    private static func isAgentRoutingCandidate(_ transcript: String) -> Bool {
        isExplicitAgentRoutingCandidate(transcript)
            || implicitAgentTaskInstruction(from: transcript) != nil
    }

    static func isExplicitAgentRoutingCandidate(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil
            || isIncompleteExplicitNewTaskRequest(from: transcript)
            || agentTaskCreationInstruction(from: transcript) != nil
            || isIncompleteAgentTaskCreationRequest(from: transcript)
            || clickyAgentInstruction(from: transcript) != nil
            || permissiveAgentInstruction(from: transcript) != nil
            || isReferentialAgentWorkFollowUp(transcript)
    }

    static func implicitAgentTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedAgentTaskInstruction(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        if let logInstruction = logEvidenceAnalysisInstruction(from: candidate) {
            return logInstruction
        }
        guard !isRawTransportDiagnosticEvent(candidate) else { return nil }
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }
        guard !isVoiceRouteCapabilityQuestion(candidate) else { return nil }
        guard !isGenericWebSearchCapabilityQuestion(candidate) else { return nil }
        guard !isConversationalPreferenceOrDesignReflection(candidate) else { return nil }
        guard !isLikelyPureConversation(candidate) else { return nil }
        guard !isInstantVoiceScreenContextRequest(candidate) else { return nil }
        guard !VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest(normalized) else { return nil }

        let hasAction = VoiceRouter.containsAgentWorkAction(normalized)
        let hasCodingImplementationCue = containsCodingImplementationCue(candidate)
        let hasToolContext = isLikelyAgentToolWorkInstruction(candidate)
            || hasAgentWorkVerbAndArtifact(candidate)
            || VoiceRouter.containsDurableWorkTarget(normalized)
            || hasCodingImplementationCue
        let asksForFreshInfo = VoiceRouter.containsFreshResearchRequest(normalized)

        guard (hasAction && hasToolContext) || hasCodingImplementationCue || asksForFreshInfo else { return nil }
        guard !isLikelyDirectLocalOnlyRequest(candidate) else { return nil }

        return SpokenText.cleanedAgentTaskInstruction(candidate)
    }

    static func logEvidenceAnalysisInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        // Focused Xcode console text can arrive through the text-mode screen
        // bridge. That is context, not a user request. In particular, local
        // transcription diagnostics are followed by the entire OpenClicky log
        // stream; treating that dump as an implicit task creates a parked
        // "Runtime Event Filter" agent and narrates its queue/failure state.
        // Keep explicit user requests plus pasted logs working, but never turn
        // this known console preamble into a task on its own.
        let normalizedOpening = candidate
            .prefix(160)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if candidate.count >= 5_000,
           candidate.localizedCaseInsensitiveContains("[OpenClickyLog]"),
           normalizedOpening.hasPrefix("error transcription: using")
            || normalizedOpening.hasPrefix("transcription: using") {
            return nil
        }

        let logEvidenceSignals = [
            "[OpenClickyLog]",
            #""event":"#,
            #""lane":"#,
            "openclicky.",
            "native_cua.",
            "voice.realtime",
            "codex.rpc",
            "messages-",
            "Transcription: using",
            "requestID",
            "executionMethod",
            "route"
        ]
        let hasLogEvidence = logEvidenceSignals.contains {
            candidate.localizedCaseInsensitiveContains($0)
        }
        guard hasLogEvidence else { return nil }

        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        let intentPattern = #"\b(?:logs?|issue|issues|error|errors|why|fix|analyse|analyze|review|inspect|look\s+at|look\s+into|find\s+out|debug|diagnose|what\s+happened|what'?s\s+wrong|make\s+a\s+note|note\s+that)\b"#
        let hasAnalysisIntent = normalized.range(of: intentPattern, options: .regularExpression) != nil

        guard hasAnalysisIntent || candidate.count >= 500 else { return nil }

        return """
        Analyze the pasted OpenClicky logs as evidence, identify the issue, and make the smallest safe fix or durable note needed. Do not route the pasted log text as a direct local app command. Original request and log evidence: \(candidate)
        """
    }

    static func smartAgentRouteDecision(from transcript: String) -> SmartAgentRouteDecision? {
        let candidate = SpokenText.normalizedAgentTaskInstruction(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        guard !isRawTransportDiagnosticEvent(candidate) else { return nil }
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }
        guard !isVoiceRouteCapabilityQuestion(candidate) else { return nil }
        guard !isGenericWebSearchCapabilityQuestion(candidate) else { return nil }
        guard !VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest(normalized) else { return nil }
        guard !isLikelyDirectLocalOnlyRequest(candidate) else { return nil }

        if let filesystemInstruction = implicitFilesystemTaskInstruction(from: candidate) {
            return SmartAgentRouteDecision(
                instruction: filesystemInstruction,
                acknowledgement: filesystemTaskAcknowledgement(from: candidate),
                reason: "local_filesystem_task",
                confidence: 0.94
            )
        }

        guard let instruction = naturalBackgroundTaskInstruction(from: candidate) else {
            return nil
        }

        return SmartAgentRouteDecision(
            instruction: instruction,
            acknowledgement: "i’ll take care of that in the background.",
            reason: "natural_background_task",
            confidence: 0.86
        )
    }

    private static func naturalBackgroundTaskInstruction(from transcript: String) -> String? {
        let candidate = cleanedNaturalBackgroundInstruction(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        guard VoiceRouter.containsNaturalBackgroundWorkCue(normalized) else { return nil }

        let hasWorkTarget = VoiceRouter.containsDurableWorkTarget(normalized)
            || VoiceRouter.containsReferentialWorkTarget(normalized)
            || isLikelyAgentToolWorkInstruction(candidate)
            || hasAgentWorkVerbAndArtifact(candidate)
            || VoiceRouter.containsFreshResearchRequest(normalized)
        guard hasWorkTarget else { return nil }
        guard !isAgentTaskPlaceholderInstruction(candidate) else { return nil }

        return candidate
    }

    private static func cleanedNaturalBackgroundInstruction(from transcript: String) -> String {
        var instruction = SpokenText.cleanedAgentTaskInstruction(SpokenText.normalizedAgentTaskInstruction(from: transcript))
        let removablePrefixes = [
            #"(?i)^\s*(?:can|could|would|will)\s+we\s+"#,
            #"(?i)^\s*(?:i\s+)?(?:want|need)\s+(?:you\s+)?to\s+"#,
            #"(?i)^\s*let'?s\s+"#
        ]
        for pattern in removablePrefixes {
            instruction = instruction.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return SpokenText.cleanedAgentTaskInstruction(instruction)
    }

    static func hybridAgentTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 5 else { return nil }
        guard !isRawTransportDiagnosticEvent(candidate) else { return nil }
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }
        guard !VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest(normalized) else { return nil }
        guard !isLikelyDirectLocalOnlyRequest(candidate) else { return nil }
        guard VoiceRouter.containsHybridForegroundCue(normalized) else { return nil }
        guard VoiceRouter.containsHybridBackgroundCue(normalized) else { return nil }

        let explicitInstruction = explicitAgentRouteInstruction(from: candidate)
            .map { SpokenText.normalizedAgentTaskInstruction(from: $0) }
            .map(SpokenText.cleanedAgentTaskInstruction)
        let implicitInstruction = implicitAgentTaskInstruction(from: candidate)
        let instruction = explicitInstruction ?? implicitInstruction ?? SpokenText.cleanedAgentTaskInstruction(candidate)
        guard !instruction.isEmpty,
              !isAgentTaskPlaceholderInstruction(instruction),
              isLikelySpecificAgentInstruction(instruction) || VoiceRouter.containsFreshResearchRequest(normalized) else {
            return nil
        }
        return instruction
    }

    private static func isRawTransportDiagnosticEvent(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let rawTransportPrefixes = [
            "/incoming]",
            "/outgoing]",
            "[incoming]",
            "[outgoing]"
        ]
        let hasRawTransportPrefix = rawTransportPrefixes.contains { prefix in
            trimmed.localizedCaseInsensitiveContains(prefix)
        }

        let rawCodexRPCSignals = [
            "codex.rpc.message",
            "codex.rpc.notification",
            "codex.rpc.request",
            #""method":"account/rateLimits/updated""#,
            "account/rateLimits/updated"
        ]
        let hasRawCodexRPCSignal = rawCodexRPCSignals.contains { signal in
            trimmed.localizedCaseInsensitiveContains(signal)
        }
        let hasRPCSummaryPayload = trimmed.localizedCaseInsensitiveContains(#""method":"#)
            && trimmed.localizedCaseInsensitiveContains(#""paramsSummary""#)

        guard hasRawTransportPrefix || hasRawCodexRPCSignal || hasRPCSummaryPayload else { return false }

        let normalized = SpokenText.normalizedSpokenCommandText(trimmed)
        let userIntentSignals = [
            "check for errors",
            "check this error",
            "check these errors",
            "fix this error",
            "fix these errors",
            "fix this",
            "fix that",
            "fix it",
            "look at this",
            "look into this",
            "review this",
            "what is this",
            "whats this",
            "what's this",
            "see issue here",
            "see the issue here"
        ]
        return !userIntentSignals.contains { normalized.hasPrefix($0) }
    }

    static func shouldEscalateVoiceResponseToAgent(responseText: String, transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        let isAgentSuitableTask = isLocalFilesystemInspectionRequest(normalizedTranscript)
            || implicitAgentTaskInstruction(from: transcript) != nil
            || smartAgentRouteDecision(from: transcript) != nil
        guard isAgentSuitableTask else { return false }

        let normalizedResponse = SpokenText.normalizedSpokenCommandText(responseText)
        let filesystemRefusalPattern = #"\b(?:i\s+(?:do\s+not|don't|dont)\s+have\s+access|i\s+(?:can't|cannot)|unable\s+to|not\s+able\s+to)\b.{0,96}\b(?:file\s*system|files?|folders?|desktop|downloads?|documents?|browse|inspect|read)\b"#
        let agentRouteRefusalPatterns = [
            #"\bthat\s+needs\s+openclicky(?:'s)?\s+agent\s+route\b"#,
            #"\bit\s+did(?:n\s*'?t| not)\s+start\s+from\s+this\s+voice\s+turn\b"#,
            #"\bneeds\s+agent\s+mode\b"#,
            #"\bstart\s+an\s+agent\b"#
        ]
        if normalizedResponse.range(of: filesystemRefusalPattern, options: .regularExpression) != nil {
            return true
        }
        return agentRouteRefusalPatterns.contains {
            normalizedResponse.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func implicitFilesystemTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        guard isLocalFilesystemInspectionRequest(normalized) else { return nil }
        guard !isInstantVoiceScreenContextRequest(candidate) else { return nil }

        return """
        Inspect the relevant local files or folders for this request, then answer succinctly: \(candidate)
        """
    }

    static func filesystemTaskAcknowledgement(from transcript: String) -> String {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        if normalized.range(of: #"\bdesktop\b"#, options: .regularExpression) != nil {
            return "i'm checking your desktop now."
        }
        if normalized.range(of: #"\bdownloads?\b"#, options: .regularExpression) != nil {
            return "i'm checking your downloads now."
        }
        if normalized.range(of: #"\bdocuments?\b"#, options: .regularExpression) != nil {
            return "i'm checking your documents now."
        }
        return "i'm checking those files now."
    }

    private static func isLocalFilesystemInspectionRequest(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:what'?s\s+on|what\s+is\s+on|list|show|check|inspect|review|find|search|look\s+at|read|summari[sz]e)\b"#
        let filesystemTargetPattern = #"\b(?:desktop|downloads?|documents?|folder|folders|file|files|directory|directories)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
            && normalized.range(of: filesystemTargetPattern, options: .regularExpression) != nil
    }

    private static func isVoiceRouteCapabilityQuestion(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        let routePattern = #"\b(?:voice\s+(?:route|lane|path)|realtime\s+(?:route|voice|path)|without\s+(?:starting\s+)?an?\s+agent|without\s+agent\s+mode|instead\s+of\s+(?:starting\s+)?an?\s+agent)\b"#
        guard normalized.range(of: routePattern, options: .regularExpression) != nil else { return false }

        let questionPattern = #"^(?:can|could|would|will)\s+you\b|^(?:can|could|would)\s+openclicky\b|^is\s+it\s+possible\b|^do\s+you\b|^does\s+openclicky\b"#
        return normalized.range(of: questionPattern, options: .regularExpression) != nil
    }

    private static func isGenericWebSearchCapabilityQuestion(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        let pattern = #"^(?:can|could|would|will)\s+you\s+(?:search\s+(?:the\s+)?web|browse\s+(?:the\s+)?web|google|look\s+things?\s+up|look\s+up\s+things?)$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isConversationalPreferenceOrDesignReflection(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return true }

        let conversationStarters = [
            "i like",
            "i love",
            "i dont like",
            "i don t like",
            "i don't like",
            "i want",
            "i only want",
            "i think",
            "i feel",
            "it feels",
            "it would be",
            "that would be",
            "would be",
            "could we",
            "can we",
            "could you talk",
            "can you talk",
            "lets talk",
            "let s talk",
            "let's talk"
        ]
        guard conversationStarters.contains(where: { normalized.hasPrefix($0) }) else {
            return false
        }

        let explicitExecutionPattern = #"\b(?:agent|start\s+(?:an?\s+)?agent|spin\s+up|get\s+(?:an?\s+)?agent|implement|patch|change\s+the\s+code|edit\s+the\s+file|write\s+the\s+file|make\s+the\s+change|do\s+the\s+change|fix\s+it\s+now)\b"#
        let naturalWorkPattern = #"\b(?:make\s+sure|ensure|verify|validate|look\s+into|sort\s+out|deal\s+with|take\s+care\s+of|get\s+(?:this|that|it|.+?)\s+working|wire\s+(?:up|in)|hook\s+(?:up|in)|diagnose|investigate)\b"#
        return !containsCodingImplementationCue(transcript)
            && normalized.range(of: explicitExecutionPattern, options: .regularExpression) == nil
            && normalized.range(of: naturalWorkPattern, options: .regularExpression) == nil
    }

    private static func isLikelyPureConversation(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return true }

        let conversationPrefixes = [
            "what is", "what are", "what does", "what do", "why", "how do", "how does",
            "how would", "can you explain", "explain", "tell me about", "walk me through",
            "do you think", "should i", "is it", "are we", "am i"
        ]
        let hasConversationPrefix = conversationPrefixes.contains { normalized.hasPrefix($0) }
        guard hasConversationPrefix else { return false }

        return !VoiceRouter.containsAgentWorkAction(normalized)
            && !isLikelyAgentToolWorkInstruction(transcript)
            && !VoiceRouter.containsDurableWorkTarget(normalized)
            && !VoiceRouter.containsFreshResearchRequest(normalized)
    }

    private static func isInstantVoiceScreenContextRequest(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        let visualReferencePatterns = [
            #"\b(?:look at|take a look at|have a look at|check|inspect|review|summari[sz]e|describe)\s+(?:this|that|it|here|my screen|the screen|what'?s on screen|the current screen|the visible screen|the current page|this page|that page|this tab|that tab|the browser|this window|that window)\b"#,
            #"\b(?:what do you think|what'?s this|what is this|what'?s that|what is that|can you see|do you see|are you seeing)\b"#
        ]
        let hasVisualReference = visualReferencePatterns.contains { pattern in
            normalized.range(of: pattern, options: .regularExpression) != nil
        }
        guard hasVisualReference else { return false }

        let longRunningSignals = #"\b(?:background|agent|task|later|keep working|while i|overnight|long|implement|patch|edit|write|code|repo|repository|github|issue|pull request|pr|file|files|folder|folders|desktop|downloads|email|gmail|calendar|research|browse|latest|web search|look up)\b"#
        return normalized.range(of: longRunningSignals, options: .regularExpression) == nil
    }

    private static func containsCodingImplementationCue(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return false }

        let conceptualQuestionPattern = #"^(?:what|why|how\s+(?:do|does|would|should)|can\s+you\s+explain|explain|tell\s+me\s+about)\b"#
        if normalized.range(of: conceptualQuestionPattern, options: .regularExpression) != nil,
           normalized.range(of: #"\b(?:make\s+the\s+change|do\s+the\s+change|change\s+the\s+code|edit\s+the\s+file|patch|implement|apply|fix\s+it\s+now)\b"#, options: .regularExpression) == nil {
            return false
        }

        let implementationVerbPattern = #"\b(?:fix|patch|implement|change|update|edit|modify|add|remove|wire|hook|route|make|build|repair|polish|improve)\b"#
        let codeTargetPattern = #"\b(?:openclicky|clicky|code|codebase|repo|repository|swift|xcode|companionmanager|app|routing|route|voice\s+(?:path|lane|route)|agent\s+(?:mode|routing|route)|computer\s+use)\b"#
        let changeRequestPattern = #"\b(?:asking\s+for|ask\s+for|requested?|need|needs|want|wants)\b.{0,80}\b(?:changes?|fixes?|code\s+fixes?|code\s+changes?)\b"#

        let hasImplementationVerb = normalized.range(of: implementationVerbPattern, options: .regularExpression) != nil
        let hasCodeTarget = normalized.range(of: codeTargetPattern, options: .regularExpression) != nil
        let hasChangeRequest = normalized.range(of: changeRequestPattern, options: .regularExpression) != nil

        return (hasImplementationVerb && hasCodeTarget) || hasChangeRequest
    }

    private static func isLikelyDirectLocalOnlyRequest(_ transcript: String) -> Bool {
        nativeTypeRequest(from: transcript) != nil
            || nativeKeyPressRequest(from: transcript) != nil
            || nativeClickRequest(from: transcript) != nil
            || localAppOpenRequest(from: transcript) != nil
            || localFolderOpenRequest(from: transcript) != nil
            || webOpenRequest(from: transcript) != nil
            || isIncompleteLocalAppOpenRequest(from: transcript)
    }

    static func deferredLiveAgentRouteInstruction(
        partialTranscript: String,
        finalTranscript: String
    ) -> String? {
        guard isAgentRoutingCandidate(partialTranscript) else { return nil }

        let normalizedFinal = SpokenText.normalizedSpokenCommandText(finalTranscript)
        guard !normalizedFinal.isEmpty else { return nil }

        let cancellationSignals = [
            "never mind",
            "nevermind",
            "ignore that",
            "forget that",
            "cancel that",
            "stop that"
        ]
        if cancellationSignals.contains(where: { normalizedFinal.contains($0) }) {
            return nil
        }

        let partialInstruction = explicitAgentRouteInstruction(from: partialTranscript)
            .map { SpokenText.normalizedAgentTaskInstruction(from: $0) }
            .map(SpokenText.cleanedAgentTaskInstruction)
        let finalInstruction = SpokenText.normalizedAgentTaskInstruction(from: finalTranscript)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))

        let finalLooksRecoverable = isLikelyAgentFollowUpPhrasing(finalTranscript)
            || isLikelyAgentToolWorkInstruction(finalTranscript)
            || hasAgentWorkVerbAndArtifact(finalTranscript)

        if finalLooksRecoverable,
           !finalInstruction.isEmpty,
           !isAgentTaskPlaceholderInstruction(finalInstruction),
           isLikelySpecificAgentInstruction(finalInstruction) {
            return finalInstruction
        }

        // If Apple Speech's final result drops the wake phrase or rewrites the
        // beginning of a long utterance, keep the last live partial that was
        // confidently classified as an agent request. This is the path for
        // "Clicky agent ..." being heard live as "click the agent ..." while
        // the final transcript only contains the trailing correction/noise.
        if let partialInstruction,
           !partialInstruction.isEmpty,
           !isAgentTaskPlaceholderInstruction(partialInstruction),
           isLikelySpecificAgentInstruction(partialInstruction) {
            return partialInstruction
        }

        return finalLooksRecoverable && !finalInstruction.isEmpty ? finalInstruction : nil
    }

    private static func explicitAgentRouteInstruction(from transcript: String) -> String? {
        if let instruction = explicitNewTaskInstruction(from: transcript) { return instruction }
        if let instruction = agentTaskCreationInstruction(from: transcript) { return instruction }
        if let instruction = clickyAgentInstruction(from: transcript) { return instruction }
        if let instruction = permissiveAgentInstruction(from: transcript) { return instruction }
        return nil
    }

    private static func hasAgentWorkVerbAndArtifact(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        let workVerbPattern = #"\b(?:create|make|build|update|change|edit|fix|design|redesign|open|show|preview|pull\s+up|find|save|export|write|review|test|run|stop|ensure|verify|validate|diagnose|investigate|repair|polish|improve|finish|wire|route)\b"#
        let artifactPattern = #"\b(?:form|page|site|website|app|file|document|report|code|repo|repository|github|issue|issues|pull\s+request|pr|folder|version|style|design|panel|overlay|status|progress|comments|logs?|tests?|thinking|calls|ui|volume|slider|control|voice|realtime|computer\s+use|tool|tools|tooling|model|models|routing|route|background|agent\s+mode)\b"#
        return normalized.range(of: workVerbPattern, options: .regularExpression) != nil
            && normalized.range(of: artifactPattern, options: .regularExpression) != nil
    }

    private static func isLikelySpecificAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return false }
        return isLikelyAgentToolWorkInstruction(instruction)
            || isReferentialAgentWorkFollowUp(instruction)
            || hasAgentWorkVerbAndArtifact(instruction)
            || normalized.contains("overlay")
            || normalized.contains("panel")
            || normalized.contains("progress")
            || normalized.contains("status")
    }

    static func isPotentialDirectComputerUseTranscript(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let directSignals = [
            "open",
            "show",
            "reveal",
            "switch",
            "press",
            "hit",
            "tap",
            "click",
            "select",
            "choose",
            "type",
            "write",
            "enter",
            "paste",
            "folder",
            "source",
            "code",
            "clicky",
            "openclicky"
        ]

        return directSignals.contains { normalizedTranscript.contains($0) }
    }

    private static func isIncompleteLocalAppOpenRequest(from transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)(?:\s+up)?[\s\.\!\?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    func startVoiceAgentTaskPlan(
        instruction: String,
        acknowledgement: String? = nil,
        route: String = "agent.start",
        speakAcknowledgement: Bool = true,
        interruptVoiceResponse: Bool = false,
        voiceContextUserTranscript: String? = nil
    ) {
        let effectiveSpeakAcknowledgement: Bool
        if suppressNextVoiceAgentStartAcknowledgement {
            effectiveSpeakAcknowledgement = false
            suppressNextVoiceAgentStartAcknowledgement = false
        } else {
            effectiveSpeakAcknowledgement = speakAcknowledgement
        }

        let plannedInstructions = Self.parallelAgentInstructions(from: instruction)
        guard plannedInstructions.count > 1 else {
            startVoiceAgentTask(
                instruction: instruction,
                acknowledgement: acknowledgement,
                route: route,
                speakAcknowledgement: effectiveSpeakAcknowledgement,
                interruptVoiceResponse: interruptVoiceResponse,
                voiceContextUserTranscript: voiceContextUserTranscript
            )
            return
        }

        let splitAcknowledgement = acknowledgement ?? "i’ll split that into \(plannedInstructions.count) background agents."
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.split_route",
            fields: [
                "originalInstruction": instruction,
                "taskCount": plannedInstructions.count,
                "executor": "agent_mode",
                "route": "\(route).split",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )

        for (index, plannedInstruction) in plannedInstructions.enumerated() {
            startVoiceAgentTask(
                instruction: plannedInstruction,
                acknowledgement: index == 0 ? splitAcknowledgement : nil,
                route: "\(route).split",
                speakAcknowledgement: effectiveSpeakAcknowledgement && index == 0,
                interruptVoiceResponse: interruptVoiceResponse && index == 0,
                voiceContextUserTranscript: voiceContextUserTranscript ?? instruction
            )
        }
    }

    private func startVoiceAgentTask(
        instruction: String,
        acknowledgement: String? = nil,
        route: String = "agent.start",
        speakAcknowledgement: Bool = true,
        interruptVoiceResponse: Bool = false,
        voiceContextUserTranscript: String? = nil
    ) {
        // Note: when the user explicitly said "agent" we do NOT route
        // through `handleDirectComputerUseRequest` here — that path
        // tries to hijack the request into Background Computer Use /
        // native CUA and fails silently when the BCU runtime isn't
        // running. Agent invocation always means "delegate to the
        // coder agent". Inline shortcuts (open-app / type / press /
        // open-folder) are still handled in `startExplicitAgentTaskIfRequested`
        // before we reach this function.
        var instruction = instruction
        if Self.isRawTransportDiagnosticEvent(instruction) {
            // A prompt that carries log evidence plus user intent is a
            // real task ("find out why these logs..."), not transport echo
            // — refuse only when no analysis instruction can be derived.
            guard let logInstruction = Self.logEvidenceAnalysisInstruction(from: instruction) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.raw_transport_event_ignored",
                    fields: [
                        "source": "voice_agent_task",
                        "instructionPreview": Self.voiceArchiveSnippet(instruction, limit: 240),
                        "requestID": activeRequestTiming?.requestID ?? "none"
                    ]
                )
                showShortSystemResponse("that looks like an internal OpenClicky runtime event, not a task.")
                return
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.log_evidence_rescued",
                fields: [
                    "source": "voice_agent_task",
                    "instructionPreview": Self.voiceArchiveSnippet(instruction, limit: 240),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            instruction = logInstruction
        }

        let startFingerprint = Self.voiceAgentStartFingerprint(
            instruction: instruction,
            route: route
        )
        let now = Date()
        if lastVoiceAgentStartFingerprint == startFingerprint,
           let previousStart = lastVoiceAgentStartAt,
           now.timeIntervalSince(previousStart) <= Self.voiceAgentStartDuplicateTTL {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.duplicate_start_suppressed",
                fields: [
                    "route": route,
                    "instruction": instruction,
                    "ageMs": Int(now.timeIntervalSince(previousStart) * 1000),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            return
        }
        lastVoiceAgentStartFingerprint = startFingerprint
        lastVoiceAgentStartAt = now

        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "instructionLength": instruction.count
            ]
        )
        if interruptVoiceResponse {
            interruptCurrentVoiceResponse()
        }
        ensureCursorOverlayVisibleForAgentTask()

        let dockItemID = UUID()
        // Keep the spoken handoff intentionally generic. The dock still gets
        // the compact task title, but voice should not read the task name
        // back when launching an agent.
        let acknowledgement = acknowledgement ?? Self.acknowledgementForAgentInstruction(instruction)
        let dockScreen = agentDockTargetScreen()
        let voiceContextTranscript = voiceContextUserTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceContextUserTranscript = (voiceContextTranscript?.isEmpty == false)
            ? voiceContextTranscript!
            : instruction

        if speakAcknowledgement {
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: "OpenClicky Agent"
            )
            rememberVoiceExchange(
                userTranscript: voiceContextUserTranscript,
                assistantResponse: acknowledgement,
                reason: "agent_start"
            )
        } else {
            rememberSilentAgentHandoff(
                userTranscript: voiceContextUserTranscript,
                instruction: instruction,
                reason: "agent_start_silent"
            )
        }

        // Spawn the dock representation while the live OpenClicky buddy makes
        // a short handoff flight to the corner and then returns to the user's
        // cursor, so the task start feels intentional without leaving the
        // working position abandoned.
        clearDetectedElementLocation()

        Task { @MainActor in
            let accentTheme = Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
            let agentSession = createAndSelectNewCodexAgentSession(
                title: Self.shortAgentInstructionSummary(instruction),
                accentTheme: accentTheme
            )
            if let timing {
                agentRequestTimingsBySessionID[agentSession.id] = timing
            }
            lastVoiceAgentStartSessionID = agentSession.id
            agentExecutionStartDatesBySessionID[agentSession.id] = executionStartedAt
            agentSessionsStartedThisLaunch.insert(agentSession.id)
            let dockItem = ClickyAgentDockItem(
                id: dockItemID,
                sessionID: agentSession.id,
                title: Self.shortAgentInstructionSummary(instruction),
                userInstruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                accentTheme: accentTheme,
                status: .starting,
                progressStageLabel: "Starting",
                progressStepText: acknowledgement,
                activityStatusLines: [acknowledgement],
                caption: acknowledgement,
                suggestedNextActions: [],
                createdAt: Date()
            )

            agentDockItems.append(dockItem)
            if agentDockItems.count > 6 {
                agentDockItems.removeFirst(agentDockItems.count - 6)
            }
            refreshAgentDockFollowBehavior()
            scheduleStatusSync()
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_task.created",
                fields: [
                    "executor": "agent_mode",
                    "executionMethod": "CodexAgentSession.submitPromptFromUI",
                    "controller": "CodexAgentSession",
                    "model": agentSession.model,
                    "sessionID": agentSession.id.uuidString,
                    "title": agentSession.title,
                    "instruction": instruction,
                    "requestID": timing?.requestID ?? "none",
                    "spawnChoreography": "cursor_to_dock_and_back",
                    "spokenAcknowledgement": speakAcknowledgement
                ]
            )
            markRequestStageCompleted(
                route: route,
                stage: "agent_created",
                stageStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "createAndSelectNewCodexAgentSession",
                    "controller": "CompanionManager",
                    "model": agentSession.model,
                    "sessionID": agentSession.id.uuidString,
                    "title": agentSession.title,
                    "spawnChoreography": "cursor_to_dock_and_back",
                    "spokenAcknowledgement": speakAcknowledgement
                ]
            )

            if let dockScreen {
                agentDockWindowManager.show(
                    companionManager: self,
                    onScreen: dockScreen,
                    position: agentParkingPosition
                )
            } else {
                showAgentDockWindowNearCurrentScreen()
            }
            animateAgentSpawnProxyFromCursorToDock(accentTheme: accentTheme, dockItemID: dockItem.id)
            submitAgentPrompt(
                instruction,
                to: agentSession,
                includeScreenContext: Self.shouldAttachScreenContext(to: instruction)
                    || pendingCircleSelectStroke != nil,
                attachPendingVoiceCircle: true
            )

            guard speakAcknowledgement else { return }
            beginCursorReplyPresentation()
            updateVoiceResponseCaption("<cursor_reply>" + acknowledgement + "</cursor_reply>", force: true, updatesDock: false)
        }
    }

    private static func voiceAgentStartFingerprint(instruction: String, route: String) -> String {
        let normalizedInstruction = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRoute = route
            .replacingOccurrences(of: #"\.split$"#, with: "", options: .regularExpression)
        return "\(normalizedRoute)|\(normalizedInstruction)"
    }

    /// Every submitted cursor request presents a real app-owned pointer/reply immediately.
    func beginCursorReplyPresentation() {
        clearDetectedElementLocation()
        cursorOverlayState.replyPointerIsPinned = true
        cursorOverlayState.replyHasVerifiedTarget = false
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screen(containingOrNearestTo: mouse) {
            let frame = screen.visibleFrame
            let anchor = CGPoint(x: min(max(mouse.x + 35, frame.minX + 20), frame.maxX - 20),
                                 y: min(max(mouse.y - 25, frame.minY + 20), frame.maxY - 20))
            detectedElementDisplayFrame = screen.frame
            detectedElementScreenLocation = anchor
            cursorOverlayState.aiPointerScreenLocation = anchor
        }
        showCursorOverlayIfAvailable()
        responseOverlayManager.beginNewReply()
        updateVoiceResponseCaption("<cursor_reply>Working…</cursor_reply>", force: true, updatesDock: false)
    }

    func ensureCursorOverlayVisibleForAgentTask() {
        showCursorOverlayIfAvailable()
    }

    func showCursorOverlayIfAvailable() {
        guard hasAccessibilityPermission else { return }
        guard !isOverlayVisible || !overlayWindowManager.isShowingOverlay() else {
            overlayWindowManager.reassertOverlayWindows()
            return
        }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func cancelPendingAgentDockItemRemoval(for sessionID: UUID) {
        pendingAgentDockItemRemovalTasks[sessionID]?.cancel()
        pendingAgentDockItemRemovalTasks.removeValue(forKey: sessionID)
    }

    private func scheduleAgentDockItemRemoval(for sessionID: UUID, delay: TimeInterval? = nil) {
        cancelPendingAgentDockItemRemoval(for: sessionID)
        guard agentDockItems.contains(where: { $0.sessionID == sessionID }) else { return }

        let effectiveDelay = delay ?? cancelledDockItemHoldDuration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.agentDockItems.removeAll { $0.sessionID == sessionID }
            if self.agentDockItems.isEmpty {
                self.agentDockWindowManager.hide()
            }
            self.pendingAgentDockItemRemovalTasks[sessionID] = nil
            self.refreshAgentDockFollowBehavior()
            self.scheduleStatusSync()
        }
        pendingAgentDockItemRemovalTasks[sessionID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: workItem)
    }

    private static func shortAgentInstructionSummary(_ instruction: String) -> String {
        var title = instruction
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'.,:;!?-–—[](){}<>"))

        if isRawTransportDiagnosticEvent(instruction) {
            return "Runtime Event Filter"
        }

        let directTitleRules: [(pattern: String, title: String)] = [
            (#"(?i)\b(?:see\s+(?:the\s+)?issue\s+here|look\s+at\s+this|fix\s+this)\b.*\b(?:OpenClickyLog|NSXPCDecoder|ViewBridge|unifiedReasons|NSXPCConnection|agent_sdk_query|_sdk_query|kDragIPC|Reentrant\s+message)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:OpenClickyLog|NSXPCDecoder|NSXPCInterface|NSXPCConnection|ViewBridge|NSViewBridgeError|Unable to obtain a task name port right|nw_protocol_instance|nw_read_request_report|unifiedReasons|agent_sdk_query|_sdk_query|Bridge SDK Message|kDragIPC|Reentrant\s+message)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:lozenge|pill|caption|label)\b.*\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b.*\b(?:lozenge|pill|caption|label)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:whole|full)\s+(?:task\s+)?names?\b"#, "Task Status Wording"),
            (#"(?i)\bshort\s+(?:version|task\s+name|name)\b"#, "Task Status Wording"),
            (#"(?i)\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b.*\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b.*\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:short|compact)\s+(?:version|label|title|name)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:proper|better|concise|short|compact)\s+(?:task\s+)?titles?\b"#, "Task Title Cleanup"),
            (#"(?i)\btask\s+titles?\b.*\b(?:read(?:ing)?\s+out|raw|asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:read(?:ing)?\s+out|raw)\b.*\b(?:asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b"#, "Task Title Stability"),
            (#"(?i)\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Stability")
        ]
        for rule in directTitleRules where title.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.title
        }

        let attachmentPathPatterns = [
            #"(?i)^/.*?\.(?:png|jpe?g|jpeg|heic|webp|gif|pdf|mov|mp4|m4v)\b"#,
            #"(?i)(?:^|\s)/(?:Users|var|tmp|private|Applications|Volumes)/\S+"#
        ]
        for pattern in attachmentPathPatterns {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let fillerPatterns = [
            #"(?i)^hey\s+(?:clicky\s+)?agent[,\s]+"#,
            #"(?i)^clicky\s+agent[,\s]+"#,
            #"(?i)^(?:can|could|would)\s+you\s+"#,
            #"(?i)^(?:please\s+)?(?:help\s+me\s+)?(?:do|make|handle|sort|take\s+care\s+of)\s+"#,
            #"(?i)^the\s+(?:updates?|changes?)\s+(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:to|for|about)\s+"#
        ]
        for pattern in fillerPatterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        title = title.replacingOccurrences(
            of: #"(?i)\b(?:please|just|maybe|basically|actually|kind\s+of|sort\s+of|you\s+know|everything\s+else)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:can\s+you|could\s+you|would\s+you|we(?:'|’)ve|we\s+have|we\s+were|talking\s+about)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:so\s+that|and\s+then|which\s+is\s+to|that\s+you)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:shorten|remove|make|making|sound|sounding|turn|change|update|fix|clean\s+up)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:the|a|an|this|that|it|them|you|your|then|also|with|from|into|and|or|but|for|of|to|in|on|as|is|are|be|have|has|had|asked)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:find|out|why|when|sure|use|uses?|using|start|starts|started|starting|speak|speaks|speaking|say|says|saying|read|reads|reading|whole|full|long|name|version|words?|thing|stuff|phrases?|responses?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(5)

        let cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "Agent Task" }
        guard cleaned.count > 44 else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: 44)
        let prefix = String(cleaned[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the spoken/displayed acknowledgement for a freshly invoked
    /// agent task. Keep it generic so OpenClicky does not speak the task
    /// name back to the user; the compact title remains visual-only in the
    /// dock and task history.
    private static func acknowledgementForAgentInstruction(_ _: String) -> String {
        "got it — i’ll get on with that in the background."
    }

    /// Record silent/hybrid agent launches as real voice context so the
    /// primary voice conversation can answer follow-ups like “what were we
    /// talking about?” and “get an agent on it” without losing the topic.
    static func agentHandoffVoiceContextResponse(instruction: String) -> String {
        let snippet = voiceArchiveSnippet(instruction, limit: 180)
        return "OpenClicky started a background agent for: \(snippet). Keep this as part of the current voice conversation context."
    }

    private static func nextAgentDockAccentTheme(existingCount: Int) -> ClickyAccentTheme {
        let accentThemes: [ClickyAccentTheme] = [.blue, .mint, .rose, .amber, .white]
        return accentThemes[existingCount % accentThemes.count]
    }

    private func updateAgentDockItem(for sessionID: UUID, status: CodexAgentSessionStatus) {
        defer { refreshCursorAgentTaskLabel() }

        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let session = codexAgentSessions.first(where: { $0.id == sessionID })
        let activitySummary = session?.latestActivitySummary
        let activityDisplaySummary = session?.latestActivityDisplaySummary ?? activitySummary
        let stageLabel = session?.progressStage.label ?? (status == .starting ? "Starting" : "Working")
        let suggestedNextActions = session?.latestResponseCard?.suggestedNextActions ?? []
        let activityStatusLines = Self.agentDockActivityStatusLines(for: session, fallback: activitySummary)
        let responseDisplaySummary = Self.agentDockResponseDisplaySummary(for: session)
        let displayActivity = responseDisplaySummary ?? activityDisplaySummary ?? activityStatusLines.last ?? activitySummary
        let trimmedActivitySummary = displayActivity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActivitySummary = trimmedActivitySummary?.isEmpty == false

        agentDockItems[itemIndex].progressStageLabel = stageLabel
        agentDockItems[itemIndex].progressStepText = hasActivitySummary ? trimmedActivitySummary : nil
        agentDockItems[itemIndex].activityStatusLines = activityStatusLines
        agentDockItems[itemIndex].suggestedNextActions = suggestedNextActions

        switch status {
        case .starting:
            agentDockItems[itemIndex].status = .starting
            // Only overwrite the caption when we actually have real assistant
            // activity. Otherwise preserve the existing caption (the user's
            // acknowledgement message) instead of replacing it with the
            // generic "An agent is getting ready." placeholder. When neither
            // is present, leave caption nil so the view can render its own
            // streaming "thinking" affordance.
            if let displayActivity, hasActivitySummary {
                agentDockItems[itemIndex].caption = displayActivity
            }
        case .running:
            agentDockItems[itemIndex].status = .running
            // Same rationale as .starting — never replace the caption with
            // "An agent is working on this." Leave nil to surface the
            // animated thinking indicator until real tokens stream in.
            if let displayActivity, hasActivitySummary {
                agentDockItems[itemIndex].caption = displayActivity
            }
        case .ready:
            // Codex briefly reports `.ready` after thread startup and before
            // the actual turn starts. Do not turn that preflight ready state
            // into "done"; assigning/queueing an agent is not task completion.
            let isCompletedTurn = session?.progressStage == .completed || responseDisplaySummary != nil
            guard isCompletedTurn else {
                // Preflight ready, even with the acknowledgement/activity text
                // we seeded at assignment time, should stay visibly queued or
                // working until a real completed turn arrives.
                return
            }
            if agentDockItems[itemIndex].status == .running
                || agentDockItems[itemIndex].status == .starting
                || (agentDockItems[itemIndex].status == .failed && isCompletedTurn) {
                agentDockItems[itemIndex].status = .done
                agentDockItems[itemIndex].caption = "The agent has completed the task — \(displayActivity ?? activitySummary ?? "open the agent for details")"
                agentDockItems[itemIndex].progressStageLabel = "Completed"
                agentDockItems[itemIndex].progressStepText = displayActivity ?? activitySummary
            }
            completeAgentRequestTimingIfNeeded(sessionID: sessionID, status: "success")
            let completionSpeechSummary = Self.completionSpeechSummary(for: session, fallback: activitySummary)
            announceAgentCompletionIfNeeded(sessionID: sessionID, outcome: "success", summary: completionSpeechSummary)
        case .failed:
            agentDockItems[itemIndex].status = .failed
            agentDockItems[itemIndex].caption = activityDisplaySummary ?? "The agent stopped. Open the agent for details."
            agentDockItems[itemIndex].progressStageLabel = "Stopped"
            agentDockItems[itemIndex].progressStepText = activityDisplaySummary ?? activitySummary
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "failed",
                extra: [
                    "activitySummary": activitySummary ?? ""
                ]
            )
            let completionSpeechSummary = Self.completionSpeechSummary(for: session, fallback: activitySummary)
            announceAgentCompletionIfNeeded(sessionID: sessionID, outcome: "failed", summary: completionSpeechSummary)
        case .stopped:
            if session?.status != .stopped {
                break
            }
            let stopReason = session?.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExplicitStopReason = stopReason?.isEmpty == false
            if agentDockItems[itemIndex].status == .starting,
               !hasExplicitStopReason {
                // New sessions publish their initial `.stopped` value once
                // the Combine observer is attached. That delivery can arrive
                // after the prompt has been queued, so `hasVisibleActivity`
                // is already true even though the agent has not actually
                // stopped. Do not convert that preflight value into an
                // immediate cancellation; wait for `.starting` / `.running`,
                // or for an explicit stop reason from a real stop action.
                break
            }
            let normalizedStopReason = stopReason?.isEmpty == false ? (stopReason ?? "") : "session_stopped"
            agentDockItems[itemIndex].status = .failed
            if let summary = activitySummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                agentDockItems[itemIndex].caption = "Cancelled while: \(summary)"
                agentDockItems[itemIndex].progressStepText = summary
            } else {
                agentDockItems[itemIndex].caption = "The agent was cancelled (\(Self.prettyCancelReason(for: normalizedStopReason)))."
                agentDockItems[itemIndex].progressStepText = Self.prettyCancelReason(for: normalizedStopReason)
            }
            agentDockItems[itemIndex].progressStageLabel = "Stopped"
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "cancelled",
                extra: [
                    "activitySummary": activitySummary ?? "",
                    "cancelledAt": Date().ISO8601Format(),
                    "cancelReason": normalizedStopReason
                ]
            )
            announceAgentCompletionIfNeeded(
                sessionID: sessionID,
                outcome: "cancelled",
                summary: Self.prettyCancelReason(for: normalizedStopReason),
                cancelReason: normalizedStopReason
            )
            break
        }
        scheduleStatusSync()
    }

    private static func agentDockActivityStatusLines(for session: CodexAgentSession?, fallback: String?) -> [String] {
        var lines: [String] = []
        for line in session?.activityStatusLines ?? [] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lines.last != trimmed {
                lines.append(trimmed)
            }
        }
        if let fallback {
            let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFallback.isEmpty, lines.last != trimmedFallback {
                lines.append(trimmedFallback)
            }
        }
        return Array(lines.suffix(8))
    }

    private static func agentDockResponseDisplaySummary(for session: CodexAgentSession?) -> String? {
        guard let raw = session?.latestResponseCard?.rawText else { return nil }
        let displayText = ClickyResponseCard.sanitizedDisplayText(from: raw, maximumCharacters: 1_200)
            .replacingOccurrences(
                of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
                with: " ",
                options: .regularExpression
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayText.isEmpty ? nil : displayText
    }

    private func refreshCursorAgentTaskLabel() {
        guard let item = agentDockItems.reversed().first(where: { dockItem in
            dockItem.status == .starting || dockItem.status == .running
        }) else {
            clearAgentTaskBubbleText()
            return
        }

        let session = item.sessionID.flatMap { sessionID in
            codexAgentSessions.first(where: { $0.id == sessionID })
        }
        let nextLabel = Self.cursorAgentTaskLabel(for: item, session: session)
        guard !nextLabel.isEmpty else {
            clearAgentTaskBubbleText()
            return
        }

        cursorOverlayState.agentTaskBubbleText = nextLabel
        scheduleAgentTaskBubbleClear(matching: nextLabel)
    }

    private func clearAgentTaskBubbleText() {
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = nil
        cursorOverlayState.agentTaskBubbleText = nil
    }

    private func scheduleAgentTaskBubbleClear(matching label: String, after delay: TimeInterval = 3.0) {
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.cursorOverlayState.agentTaskBubbleText == label else { return }
                self.cursorOverlayState.agentTaskBubbleText = nil
                self.agentTaskBubbleClearTask = nil
            }
        }
    }

    private static func cursorAgentTaskLabel(for item: ClickyAgentDockItem, session: CodexAgentSession?) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Agent task" : title
        let stageLabel = session?.progressStage.label ?? (item.status == .starting ? "Starting" : "Working")

        // The cursor bubble is only a transient cue; the dock/HUD owns detailed progress.
        // Keeping it title-based prevents long streamed status lines from wrapping into
        // clipped, ellipsis-heavy captions beside the cursor.
        return shortCursorAgentTaskLabel("\(stageLabel): \(fallbackTitle)")
    }

    private static func shortCursorAgentTaskLabel(_ text: String) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let maxCharacters = 64
        guard flattened.count > maxCharacters else { return flattened }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxCharacters)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeAgentRequestTimingIfNeeded(
        sessionID: UUID,
        status: String,
        extra: [String: Any] = [:]
    ) {
        let timing = agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        let executionStartedAt = agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        // Drop the dedup signature for terminal sessions so the map can't
        // grow without bound across long-running OpenClicky sessions.
        lastAgentProgressNarrationSignatures.removeValue(forKey: sessionID)
        guard timing != nil || executionStartedAt != nil else { return }

        var fields = extra
        if status == "cancelled" {
            if fields["cancelledAt"] == nil {
                fields["cancelledAt"] = Date().ISO8601Format()
            }
            if fields["cancelReason"] == nil,
               let stoppedSession = codexAgentSessions.first(where: { $0.id == sessionID })?.stopReason,
               !stoppedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["cancelReason"] = stoppedSession
            }
            fields["executionMethod"] = "CodexAgentSession.status"
            fields["executionStatus"] = "cancelled"
        }

        fields["sessionID"] = sessionID.uuidString
        fields["executor"] = "agent_mode"
        fields["executionMethod"] = fields["executionMethod"] as? String ?? "CodexAgentSession.status"
        fields["controller"] = "CodexAgentSession"
        markRequestCompleted(
            route: "agent.start",
            executionStartedAt: executionStartedAt,
            timing: timing,
            status: status,
            extra: fields
        )
    }

    /// Speaks a short completion line the first time a delegated agent
    /// reaches a terminal outcome. Suppresses duplicate announcements
    /// when Combine republishes, and avoids stepping on a voice response
    /// that's already mid-flight.
    private func announceAgentCompletionIfNeeded(
        sessionID: UUID,
        outcome: String,
        summary: String?,
        cancelReason: String? = nil
    ) {
        if lastNarratedAgentOutcomeBySessionID[sessionID] == outcome { return }
        lastNarratedAgentOutcomeBySessionID[sessionID] = outcome

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
        let taskTitle = Self.agentCompletionSpokenTaskTitle(for: session)

        // User-initiated cancellation: the user just clicked Stop / said
        // "cancel" — they already know what happened. Don't narrate it back.
        // Only system-initiated cancellations get spoken/notified (those would
        // otherwise be invisible to the user).
        if outcome == "cancelled", Self.isUserInitiatedCancelReason(cancelReason) {
            return
        }

        let trimmedSummary = summary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line: String
        switch outcome {
        case "cancelled":
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) was cancelled"
                : "\(taskTitle) was cancelled: \(Self.briefCompletionSummary(trimmedSummary))"
        case "failed":
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) stopped"
                : "\(taskTitle) stopped: \(Self.briefCompletionSummary(trimmedSummary))"
        default:
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) is done"
                : "\(taskTitle) is done: \(Self.briefCompletionSummary(trimmedSummary))"
        }

        let notificationTitle: String
        switch outcome {
        case "cancelled": notificationTitle = "OpenClicky task cancelled"
        case "failed": notificationTitle = "OpenClicky task stopped"
        default: notificationTitle = "OpenClicky task done"
        }
        OpenClickyDesktopNotificationCenter.shared.post(
            title: notificationTitle,
            body: line,
            threadID: "openclicky.agent.\(sessionID.uuidString)",
            playSound: outcome == "success",
            userInfo: [
                "source": "agent_completion",
                "sessionID": sessionID.uuidString,
                "outcome": outcome
            ]
        )

        // Spoken replies are muted by default and notifications can be off, so show the result by the pointer
        // unless an answer is on screen right now.
        if currentResponseTask == nil, outcome != "cancelled", agentSessionsStartedThisLaunch.contains(sessionID) {
            beginCursorReplyPresentation()
            updateVoiceResponseCaption("<cursor_reply>" + line + "</cursor_reply>", force: true, updatesDock: false)
        }

        guard AppBundleConfiguration.agentCompletionVoiceEnabled() else { return }

        // Skip narration if the user is mid-conversation with the voice
        // responder — the dock item still updates visually, and the desktop
        // notification now carries the update without talking over them.
        if voiceState == .listening { return }

        // Sequence behind any in-flight TTS or voice capture instead of
        // cutting in. The queued path is important: an agent can finish
        // while the user has already started the next push-to-talk turn,
        // and completion speech must not feed back into the microphone.
        // Previously this called `showShortSystemResponse(line)` directly,
        // whose `interruptCurrentVoiceResponse()` would chop the
        // acknowledgement TTS mid-sentence when fast tasks completed
        // before the acknowledgement finished playing. Now we wait for
        // the audio device to go idle, then play the chime (success
        // only), then speak the announcement — so the success line is
        // always heard, never elided, and never overlaps prior audio.
        let playChime = (outcome == "success")
        speakSystemAnnouncementAfterCurrentTTS(line, for: sessionID, withChime: playChime)
    }

    private static func agentCompletionSpokenTaskTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "Agent" else {
            return "the agent task"
        }
        return title
    }

    /// Queue a system announcement to play *after* any currently-playing
    /// TTS finishes. Polls `voiceTTSClient.isPlaying` rather than awaiting
    /// a Task, because the relevant signal is "audio device idle", not
    /// "Swift Task completed" — TTS playback can outlive its dispatching
    /// task by a few hundred milliseconds while audio buffers drain.
    ///
    /// When `withChime` is true, the agent-done chime is played first,
    /// followed by a settle gap, then the announcement. This is how
    /// success completion announces — chime, then the spoken summary.
    /// Play an agent-completion announcement. Chime first (if requested),
    /// then the spoken line. Anything currently playing is cut so the
    /// chime never overlaps speech and never gets cut by speech.
    private func speakSystemAnnouncementAfterCurrentTTS(
        _ line: String,
        for sessionID: UUID?,
        withChime: Bool = false
    ) {
        let previousTask = pendingSystemAnnouncementTask
        pendingSystemAnnouncementSessionID = sessionID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                _ = await previousTask.result
            }
            if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
            if Task.isCancelled { return }
            guard await self.waitForSystemAnnouncementSlot(sessionID: sessionID) else { return }
            if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
            if withChime {
                let chimeDuration = self.playAgentDoneChime()
                let settleSeconds = max(0.12, chimeDuration + 0.08)
                try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
                guard await self.waitForSystemAnnouncementSlot(sessionID: sessionID) else { return }
            }
            self.speakingSystemAnnouncementSessionID = sessionID
            self.showShortSystemResponse(line, interruptExisting: false)
            await self.waitForVoicePlaybackToIdle()
            if self.speakingSystemAnnouncementSessionID == sessionID {
                self.speakingSystemAnnouncementSessionID = nil
            }
            if self.pendingSystemAnnouncementSessionID == sessionID {
                self.pendingSystemAnnouncementTask = nil
                self.pendingSystemAnnouncementSessionID = nil
            }
        }
        pendingSystemAnnouncementTask = task
    }

    private func silenceAgentSpeech(for sessionID: UUID, reason: String) {
        var didSilenceSpeech = false
        silencedAgentSpeechSessionIDs.insert(sessionID)
        if pendingSystemAnnouncementSessionID == sessionID {
            pendingSystemAnnouncementTask?.cancel()
            pendingSystemAnnouncementTask = nil
            pendingSystemAnnouncementSessionID = nil
            didSilenceSpeech = true
        }
        if speakingSystemAnnouncementSessionID == sessionID {
            interruptCurrentVoiceResponse()
            speakingSystemAnnouncementSessionID = nil
            didSilenceSpeech = true
        }
        guard didSilenceSpeech else { return }
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.speech_silenced",
            fields: [
                "sessionID": sessionID.uuidString,
                "reason": reason
            ]
        )
    }

    @MainActor
    private func waitForVoicePlaybackToIdle(maxWaitSeconds: TimeInterval = 8.0) async {
        let start = Date()
        while voiceState == .responding {
            if Task.isCancelled { return }
            if Date().timeIntervalSince(start) >= maxWaitSeconds { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func waitForSystemAnnouncementSlot(
        sessionID: UUID?,
        maxWaitSeconds: TimeInterval = 30.0
    ) async -> Bool {
        let start = Date()
        while systemAnnouncementAudioWouldCollideWithVoiceInput {
            if Task.isCancelled { return false }
            if let sessionID, silencedAgentSpeechSessionIDs.contains(sessionID) { return false }
            if Date().timeIntervalSince(start) >= maxWaitSeconds {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.agent_completion.speech_deferred_timeout",
                    fields: [
                        "sessionID": sessionID?.uuidString ?? "",
                        "voiceState": String(describing: voiceState),
                        "dictationInProgress": buddyDictationManager.isDictationInProgress,
                        "dictationActive": buddyDictationManager.isDictationInProgress
                    ]
                )
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @MainActor
    private var systemAnnouncementAudioWouldCollideWithVoiceInput: Bool {
        if buddyDictationManager.isDictationInProgress { return true }
        switch voiceState {
        case .listening, .processing, .responding:
            return true
        case .idle:
            return false
        }
    }

    /// Play the bundled "agent-done" chime via NSSound on a system
    /// audio channel separate from TTS. Caller is responsible for
    /// timing this so it doesn't overlap in-flight TTS.
    @discardableResult
    private func playAgentDoneChime() -> TimeInterval {
        guard let url = Bundle.main.url(forResource: "agent-done", withExtension: "mp3") else {
            return 0.55
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            return 0.55
        }
        sound.play()
        return sound.duration > 0 ? sound.duration : 0.55
    }

    /// Trims an agent activity summary to a sentence-length spoken line.
    /// Activity summaries can be multi-line tool output; we want one
    /// short clause for TTS.
    private static func prettyCancelReason(for reason: String) -> String {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "", "unknown", "session_stopped":
            return "session was stopped"
        case "agent.cancel_current", "agent.cancel":
            return "the user requested cancellation"
        case "agent.cancel_all":
            return "all agents were cancelled"
        case "agent_dock_stop":
            return "dock stop"
        case "response_card_dismissed":
            return "response card dismissed"
        case "api_key_reconfigured":
            return "API configuration changed"
        case "model_changed":
            return "model changed"
        default:
            return reason
        }
    }

    /// Whether a cancellation reason was *initiated by the user* (Stop
    /// click, "cancel" voice command, dismiss response card). Those
    /// cancellations should be silent — the user already knows. Only
    /// system-initiated cancellations (API key changed, model changed,
    /// session externally stopped with no other context) get spoken.
    private static func isUserInitiatedCancelReason(_ reason: String?) -> Bool {
        guard let reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !reason.isEmpty else {
            return false
        }
        switch reason {
        case "agent_dock_stop",
             "agent.cancel",
             "agent.cancel_current",
             "agent.cancel_all",
             "response_card_dismissed":
            return true
        case "api_key_reconfigured",
             "model_changed",
             "session_stopped",
             "unknown":
            return false
        default:
            // For anything else, default to "system" — user-initiated
            // reasons are explicit and known. Unknown reasons get a
            // narration so the user can find out what happened.
            return false
        }
    }

    private static func briefCompletionSummary(_ summary: String) -> String {
        cleanedNaturalSpeech(summary, maxLength: 180)
    }

    /// For completion TTS, use a short cleaned final-response summary after
    /// the compact task title. Do not read the whole task or result aloud.
    private static func completionSpeechSummary(
        for session: CodexAgentSession?,
        fallback: String?
    ) -> String? {
        if let raw = session?.latestResponseCard?.rawText {
            var text = ClickyResponseCard.sanitizedDisplayText(from: raw, maximumCharacters: 10_000)
            text = text.replacingOccurrences(
                of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
                with: " ",
                options: .regularExpression
            )
            text = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let maxSpokenLength = 180
                let cleaned = cleanedNaturalSpeech(text, maxLength: maxSpokenLength)
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "outgoing",
                    event: "openclicky.agent_completion.speech_budget",
                    fields: [
                        "rawLength": raw.count,
                        "sanitizedLength": text.count,
                        "spokenLength": cleaned.count,
                        "maxLength": maxSpokenLength
                    ]
                )
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        if let fallback {
            let maxSpokenLength = 180
            let cleaned = cleanedNaturalSpeech(fallback, maxLength: maxSpokenLength)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_completion.speech_budget",
                fields: [
                    "rawLength": fallback.count,
                    "sanitizedLength": fallback.count,
                    "spokenLength": cleaned.count,
                    "maxLength": maxSpokenLength,
                    "source": "fallback"
                ]
            )
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// Sanitizes assistant text into short, natural spoken English for TTS.
    /// Removes paths/filenames and punctuation-heavy fragments that sound
    /// robotic when read aloud.
    private static func cleanedNaturalSpeech(_ text: String, maxLength: Int) -> String {
        var value = text
        value = trimmedCompletionSpeechBeforeTechnicalTail(value)
        value = value.replacingOccurrences(
            of: #"(?is)\s+(?:in|at|under|inside)\s+`?(?:/Users|/Volumes|~)/[^\s,;:()\[\]{}<>"]+`?"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?i)\b(?:/Users|/Volumes|~)/[^\s,;:()\[\]{}<>"]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b\S+\.(swift|md|json|jsonl|toml|yaml|yml|txt|csv|ts|tsx|js|jsx|py|sh)\b"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
        value = Self.naturallyBoundedCompletionSpeech(value, maxLength: maxLength)
        value = value.replacingOccurrences(of: #"[#*_>\[\]\(\)\{\}:;|\\/]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[-–—]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[.!?,]+"#, with: " ", options: .regularExpression)
        value = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard value.count > maxLength else { return value }
        let endIndex = value.index(value.startIndex, offsetBy: maxLength)
        let prefix = String(value[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps spoken task-completion summaries from sounding like the
    /// audio was cut off. Prefer a real sentence boundary; when the
    /// only available text is long, end with a deliberate handoff to
    /// the on-screen task transcript instead of stopping mid-thought.
    private static func naturallyBoundedCompletionSpeech(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxLength else { return flattened }

        let limitIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<limitIndex])
        let minimumBoundary = flattened.index(
            flattened.startIndex,
            offsetBy: min(70, max(0, flattened.count - 1))
        )
        if let sentenceBreak = prefix.lastIndex(where: { ".!?".contains($0) }),
           sentenceBreak >= minimumBoundary {
            return String(prefix[...sentenceBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix = " Details are in the task."
        let allowedPrefixLength = max(40, maxLength - suffix.count)
        let allowedIndex = prefix.index(prefix.startIndex, offsetBy: min(prefix.count, allowedPrefixLength))
        let boundedPrefix = String(prefix[..<allowedIndex])
        if let lastComma = boundedPrefix.lastIndex(where: { ",;".contains($0) }),
           lastComma > boundedPrefix.startIndex {
            return String(boundedPrefix[..<lastComma]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }
        if let lastSpace = boundedPrefix.lastIndex(of: " "), lastSpace > boundedPrefix.startIndex {
            return String(boundedPrefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }
        return boundedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    /// Agent final replies often include useful transcript detail like
    /// "Verified with `swiftc -parse` and `git diff --check`". That is good
    /// on-screen, but TTS used to read up to "verified with" and then lose the
    /// code-like command names. Stop before those verification tails so the
    /// spoken completion stays natural.
    private static func trimmedCompletionSpeechBeforeTechnicalTail(_ text: String) -> String {
        var value = text
        let technicalTailPatterns = [
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?verified\s+(?:it\s+)?with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?verified\s+with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?(?:checked|tested)\s+(?:it\s+)?with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?verified\b[^.!?]*(?:swiftc|git\s+diff|diff\s+--check|xcodebuild|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#
        ]
        for pattern in technicalTailPatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openAgentDockItem(_ itemID: UUID) {
        if showCompactConversationForAgentDockItem(itemID) { return }
        guard isAdvancedModeEnabled else {
            prepareVoiceFollowUpForAgentDockItem(itemID)
            return
        }
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID {
            selectCodexAgentSession(sessionID)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_overlay.opened_selection_only",
                fields: [
                    "source": "agent_overlay_open",
                    "sessionID": sessionID.uuidString
                ]
            )
            showAgentTask(sessionID)
            return
        }
        showAgentTask(nil)
    }

    /// Opens an agent task's conversation in the compact panel, or the current compact task when none is given.
    func showAgentTask(_ sessionID: UUID?) {
        if let sessionID {
            selectCodexAgentSession(sessionID)
            if showCompactConversationForAgentDockItem(sessionID) { return }
        }
        showTutorConversation()
    }

    func closeAgentDockPanel() {
        agentDockWindowManager.hide()
    }

    func dismissAgentDockItem(_ itemID: UUID) {
        // The dock/menu "Archive" affordance should archive the underlying
        // task, not just hide its visual parked/menu item. Menu-bar task
        // items may be synthesized directly from Codex sessions, so their
        // item ID is the session ID and there may be no matching dock item.
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
            ?? codexAgentSessions.first(where: { $0.id == itemID })?.id {
            cancelPendingAgentDockItemRemoval(for: sessionID)
            archiveSession(sessionID, allowIncomplete: true)
            return
        }

        // Unsessioned completed cues are visual-only; remove those directly.
        agentDockItems.removeAll { $0.id == itemID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleStatusSync()
    }

    func stopAgentDockItem(_ itemID: UUID) {
        if let stoppedSessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
            ?? codexAgentSessions.first(where: { $0.id == itemID })?.id {
            cancelAgentTask(sessionID: stoppedSessionID, removeDockItems: true, reason: "agent_dock_stop")
            lastNarratedAgentOutcomeBySessionID.removeValue(forKey: stoppedSessionID)
        } else {
            agentDockItems.removeAll { $0.id == itemID }
            if agentDockItems.isEmpty {
                agentDockWindowManager.hide()
            }
            scheduleStatusSync()
        }
    }

    func prepareVoiceFollowUpForAgentDockItem(_ itemID: UUID) {
        if itemID == tutorDockItemID { showTutorInput(startDictation: true); return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else {
            prepareForVoiceFollowUp()
            return
        }
        armVoiceFollowUpTarget(sessionID, source: "agent_overlay_voice_button")
        prepareForVoiceFollowUp()
    }

    func armVoiceFollowUpTarget(_ sessionID: UUID, source: String) {
        pendingAgentVoiceFollowUpSessionID = sessionID
        pendingAgentVoiceFollowUpCreatedAt = Date()
        pendingAgentVoiceFollowUpSource = source
        selectCodexAgentSession(sessionID)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "internal",
            event: "openclicky.agent_followup.voice_target_armed",
            fields: [
                "source": source,
                "sessionID": sessionID.uuidString,
                "ttlSeconds": Int(Self.pendingAgentVoiceFollowUpTTL)
            ]
        )
    }

    func showTextFollowUpForAgentDockItem(_ itemID: UUID) {
        if itemID == tutorDockItemID { showTutorInput(startDictation: false); return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else { return }
        showTextFollowUpForAgentSession(sessionID)
    }

    func showTextFollowUpForAgentSession(_ sessionID: UUID) {
        selectCodexAgentSession(sessionID)
        showNotchTextInput { [weak self] submittedText in
            self?.submitTextFollowUp(submittedText, toAgentSessionID: sessionID)
        }
    }

    func beginAgentDockDrag() {
        agentDockWindowManager.beginDrag()
    }

    func dragAgentDock(by translation: CGSize) {
        agentDockWindowManager.drag(by: translation)
    }

    func endAgentDockDrag() {
        agentDockWindowManager.endDrag()
    }

    func submitTextFollowUp(_ submittedText: String, toAgentSessionID sessionID: UUID) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_followup.missing_session",
                fields: [
                    "source": "agent_text_followup",
                    "sessionID": sessionID.uuidString,
                    "instructionLength": trimmedText.count
                ]
            )
            return
        }
        let timing = beginRequestTiming(source: "agent_text_followup", text: trimmedText)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedText.count
            ]
        )
        submitAgentPrompt(trimmedText, to: session)
        lastAgentContextSessionID = session.id
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
    }

    func attachDroppedAgentFiles(_ urls: [URL], toAgentDockItem itemID: UUID, source: String) {
        let standardizedURLs = urls
            .map(\.standardizedFileURL)
            .filter(\.isFileURL)
        guard !standardizedURLs.isEmpty else { return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID,
              let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_attachment_drop.missing_session",
                fields: [
                    "source": source,
                    "itemID": itemID.uuidString,
                    "attachmentCount": standardizedURLs.count
                ]
            )
            return
        }

        let prompt = Self.agentAttachmentPrompt(for: standardizedURLs)
        let timing = beginRequestTiming(source: source, text: prompt)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "attachmentCount": standardizedURLs.count
            ]
        )

        selectCodexAgentSession(session.id)
        submitAgentPrompt(prompt, to: session)
        lastAgentContextSessionID = session.id

        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model,
                "attachmentCount": standardizedURLs.count
            ]
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_attachment_drop.received",
            fields: [
                "source": source,
                "sessionID": session.id.uuidString,
                "attachmentCount": standardizedURLs.count
            ]
        )
    }

    private static func agentAttachmentPrompt(for urls: [URL]) -> String {
        let attachmentLines = urls.enumerated().map { index, url in
            "\(index + 1). \(agentAttachmentKindLabel(for: url)): \(url.path)"
        }.joined(separator: "\n")

        return """
        Please review the attached file(s).

        OpenClicky dropped attachments:
        \(attachmentLines)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func agentAttachmentKindLabel(for url: URL) -> String {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ? "Image" : "Document"
    }

    @discardableResult
    func submitNewAgentTaskFromUI(_ prompt: String, source: String = "agent_new_task_prompt") -> CodexAgentSession? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }
        var taskPrompt = trimmedPrompt
        if Self.isRawTransportDiagnosticEvent(trimmedPrompt) {
            // Typed/pasted prompts that mix user intent with log evidence
            // are real tasks; only refuse pure transport echo that yields
            // no analysis instruction.
            guard let logInstruction = Self.logEvidenceAnalysisInstruction(from: trimmedPrompt) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.raw_transport_event_ignored",
                    fields: [
                        "source": source,
                        "instructionPreview": Self.voiceArchiveSnippet(trimmedPrompt, limit: 240)
                    ]
                )
                showShortSystemResponse("that looks like an internal OpenClicky runtime event, not a task.")
                return nil
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.log_evidence_rescued",
                fields: [
                    "source": source,
                    "instructionPreview": Self.voiceArchiveSnippet(trimmedPrompt, limit: 240)
                ]
            )
            taskPrompt = logInstruction
        }

        let timing = beginRequestTiming(source: source, text: trimmedPrompt)
        activeRequestTiming = timing
        defer { activeRequestTiming = nil }

        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.new_task",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "instructionLength": trimmedPrompt.count
            ]
        )

        let launchPrompt = resolvedNewAgentTaskPrompt(from: taskPrompt)

        let session = createAndLaunchCodexAgentSession(
            title: Self.shortAgentInstructionSummary(launchPrompt),
            prompt: launchPrompt,
            includeScreenContext: Self.shouldAttachScreenContext(to: launchPrompt)
        )
        agentRequestTimingsBySessionID[session.id] = timing
        agentExecutionStartDatesBySessionID[session.id] = executionStartedAt
        agentSessionsStartedThisLaunch.insert(session.id)

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.created",
            fields: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "model": session.model,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instruction": launchPrompt,
                "originalInstruction": trimmedPrompt,
                "requestID": timing.requestID,
                "source": source
            ]
        )

        markRequestStageCompleted(
            route: "agent.new_task",
            stage: "agent_queued",
            stageStartedAt: executionStartedAt,
            timing: timing,
            status: "queued",
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        return session
    }

    func submitAgentPromptFromUI(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let timing = beginRequestTiming(source: "agent_hud_prompt", text: trimmedPrompt)
        activeRequestTiming = timing
        defer { activeRequestTiming = nil }
        if handleAgentSelectionRequestIfNeeded(from: trimmedPrompt, source: "agent_hud_prompt") {
            return
        }

        if !Self.shouldSendAgentHUDPromptStraightToAgent(trimmedPrompt),
           handleDirectComputerUseRequest(from: trimmedPrompt, source: "agent_hud_prompt") {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_prompt.intercepted_native_cua",
                fields: [
                    "source": "agent_hud_prompt",
                    "instruction": trimmedPrompt,
                    "requestID": timing.requestID
                ]
            )
            return
        }

        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_hud_prompt",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "instructionLength": trimmedPrompt.count
            ]
        )
        if codexAgentSession.isTurnActiveForChatQueue {
            codexAgentSession.submitPromptFromUI(trimmedPrompt, screenContext: nil)
        } else {
            stageDashboardAgentSubmission(prompt: trimmedPrompt, session: codexAgentSession)
            submitAgentPrompt(trimmedPrompt, to: codexAgentSession)
        }
        markRequestStageCompleted(
            route: "agent.followup",
            stage: "prompt_queued",
            stageStartedAt: executionStartedAt,
            timing: timing,
            status: "queued",
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_hud_prompt",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "model": codexAgentSession.model
            ]
        )
    }

    private static func shouldSendAgentHUDPromptStraightToAgent(_ prompt: String) -> Bool {
        let lineBreakCount = prompt.reduce(0) { partial, character in
            partial + (character.isNewline ? 1 : 0)
        }
        guard lineBreakCount > 0 else { return false }

        let normalized = prompt.lowercased()
        let pastedDiagnosticSignals = [
            "[openclickylog]",
            "openclicky:",
            "voice.realtime_bidirectional",
            "codex.rpc",
            "nw_read_request_report",
            "error domain=",
            "throwing -",
            "failed!"
        ]
        return pastedDiagnosticSignals.contains { normalized.contains($0) }
    }

    /// Keeps chat-driven turns aligned with the same corner-dock UX as
    /// voice starts: hoverable dock card and a quick buddy flight to the
    /// parking corner before returning to the user's cursor.
    func stageDashboardAgentSubmission(prompt: String, session: CodexAgentSession) {
        let summary = Self.shortAgentInstructionSummary(prompt)
        let activity = "Starting \(summary)"
        let screen = agentDockTargetScreen()
        clearDetectedElementLocation()

        let spawnAccentTheme: ClickyAccentTheme
        let spawnDockItemID: UUID
        if let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == session.id }) {
            agentDockItems[itemIndex].title = summary
            agentDockItems[itemIndex].userInstruction = prompt
            agentDockItems[itemIndex].status = .starting
            agentDockItems[itemIndex].progressStageLabel = "Starting"
            agentDockItems[itemIndex].progressStepText = activity
            agentDockItems[itemIndex].activityStatusLines = [activity]
            agentDockItems[itemIndex].caption = "on it."
            spawnAccentTheme = agentDockItems[itemIndex].accentTheme
            spawnDockItemID = agentDockItems[itemIndex].id
        } else {
            let accentTheme = Self.nextAgentDockAccentTheme(existingCount: agentDockItems.count)
            let dockItem = ClickyAgentDockItem(
                id: UUID(),
                sessionID: session.id,
                title: summary,
                userInstruction: prompt,
                accentTheme: accentTheme,
                status: .starting,
                progressStageLabel: "Starting",
                progressStepText: activity,
                activityStatusLines: [activity],
                caption: "on it.",
                suggestedNextActions: [],
                createdAt: Date()
            )
            agentDockItems.append(dockItem)
            if agentDockItems.count > 6 {
                agentDockItems.removeFirst(agentDockItems.count - 6)
            }
            spawnAccentTheme = accentTheme
            spawnDockItemID = dockItem.id
        }

        refreshAgentDockFollowBehavior()
        scheduleStatusSync()

        if let screen {
            agentDockWindowManager.show(
                companionManager: self,
                onScreen: screen,
                position: agentParkingPosition
            )
        } else {
            showAgentDockWindowNearCurrentScreen()
        }
        animateAgentSpawnProxyFromCursorToDock(accentTheme: spawnAccentTheme, dockItemID: spawnDockItemID)
    }

    func submitAgentPrompt(
        _ prompt: String,
        to session: CodexAgentSession,
        includeScreenContext: Bool = true,
        attachPendingVoiceCircle: Bool = false
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        lastAgentContextSessionID = session.id
        activeCodexAgentSessionID = session.id
        let baselinePasteboardChangeCount = NSPasteboard.general.changeCount
        let forceClipboardSelection = Self.shouldForceAgentClipboardSelection(for: trimmedPrompt)
        OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "agent_prompt")
        Task {
            // Agent allocation should not make the main OpenClicky panel feel
            // frozen. Stage the dock card synchronously, then let the run loop
            // render pending panel/window changes before screen-context capture
            // and Codex process startup begin.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))

            // A freehand selection is scoped to the voice turn that explicitly
            // requested it. Typed HUD and delayed background prompts must never
            // inherit a prior sensitive crop.
            if attachPendingVoiceCircle,
               includeScreenContext,
               handoffQueue.allSatisfy({ !$0.selection.hasFreehandPath }),
               let circleHandoff = await consumePendingCircleSelectHandoff(instruction: trimmedPrompt) {
                queueHandoffRegion(selection: circleHandoff.selection, imageData: circleHandoff.imageData)
            }

            let screenContext = includeScreenContext ? await prepareAgentScreenContextForNextTurn(
                minimumPasteboardChangeCount: baselinePasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ) : nil
            if !includeScreenContext {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.agent_screen_context.skipped",
                    fields: [
                        "reason": "text_only_agent_turn",
                        "sessionID": session.id.uuidString,
                        "instructionLength": trimmedPrompt.count
                    ]
                )
            }
            session.submitPromptFromUI(trimmedPrompt, screenContext: screenContext)
        }
    }

    func interruptCurrentVoiceResponse() {
        cursorOverlayState.replyPointerIsPinned = false
        currentVoiceResponseCancellationHandler?("interrupted")
        currentVoiceResponseCancellationHandler = nil
        currentVoiceResponseRequestID = nil
        currentVoiceResponseCompletionToken = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskToken = nil
        codexVoiceSession.cancelActiveTurn(reason: "voice_response_interrupted")
        clearVoiceResponseCaptionAndInteractiveBubble()
        if !buddyDictationManager.isDictationInProgress {
            currentAudioPowerLevel = 0
            voiceState = .idle
        }
    }

    private func prepareAgentScreenContextForNextTurn(
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) async -> CodexAgentScreenContext? {
        // Drop stale circle-while-talking regions so an older hold cannot
        // leak into an unrelated agent turn.
        let circleHandoffMaxAge: TimeInterval = 45
        let now = Date()
        handoffQueue.removeAll { queued in
            queued.selection.hasFreehandPath
                && now.timeIntervalSince(queued.queuedAt) > circleHandoffMaxAge
        }

        if !handoffQueue.isEmpty {
            let queuedRegions = handoffQueue
            do {
                let context = try writeQueuedHandoffScreenContext(
                    queuedRegions,
                    minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                    forceClipboardSelection: forceClipboardSelection
                )
                handoffQueue.removeAll { queued in
                    queuedRegions.contains { $0.id == queued.id }
                }
                return context
            } catch {
                print("OpenClicky Agent Mode: failed to write queued screen context: \(error)")
            }
        }

        do {
            if selectedComputerUseBackend == .backgroundComputerUse {
                do {
                    let capture = try await backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                    return try writeBackgroundComputerUseScreenContext(
                        capture,
                        minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                        forceClipboardSelection: forceClipboardSelection
                    )
                } catch {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "background_computer_use.screen_context_error",
                        fields: [
                            "backend": selectedComputerUseBackend.rawValue,
                            "error": error.localizedDescription,
                            "status": backgroundComputerUseController.status.summary
                        ]
                    )
                    print("OpenClicky Agent Mode: Background Computer Use context unavailable: \(error)")
                }
            } else if nativeComputerUseController.isEnabled {
                do {
                    let capture = try await nativeComputerUseController.captureFocusedWindowAsJPEG()
                    return try writeNativeComputerUseScreenContext(
                        capture,
                        minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                        forceClipboardSelection: forceClipboardSelection
                    )
                } catch {
                    print("OpenClicky Agent Mode: native CUA Swift focused-window context unavailable: \(error)")
                }
            }

            let captures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
            return try writeCapturedScreenContext(
                captures,
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            )
        } catch {
            print("OpenClicky Agent Mode: current screen context unavailable: \(error)")
            return nil
        }
    }

    private func writeQueuedHandoffScreenContext(
        _ queuedRegions: [HandoffQueuedRegionScreenshot],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try queuedRegions.enumerated().map { index, queuedRegion in
            let fileURL = directory.appendingPathComponent("\(batchID)-handoff-\(index + 1).jpg", isDirectory: false)
            try queuedRegion.imageData.write(to: fileURL, options: .atomic)

            let rect = queuedRegion.selection.captureRect
            let comment = queuedRegion.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            var noteParts: [String] = [
                "Selected region x:\(Int(rect.minX)) y:\(Int(rect.minY)) width:\(Int(rect.width)) height:\(Int(rect.height))."
            ]
            if queuedRegion.selection.hasFreehandPath {
                noteParts.append(
                    "User freehand-circled this region while speaking (\(queuedRegion.selection.pathPoints.count) path points)."
                )
            }
            let ambient = queuedRegion.selection.ambientSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ambient.isEmpty {
                noteParts.append(ambient)
            }
            if !comment.isEmpty {
                noteParts.append("User note / instruction: \(comment)")
            }

            return CodexAgentScreenContextAttachment(
                label: queuedRegion.selection.hasFreehandPath
                    ? "Circled handoff region \(index + 1)"
                    : "Queued handoff region \(index + 1)",
                fileURL: fileURL,
                note: noteParts.joined(separator: " ")
            )
        }

        let queuedNotes = queuedRegions
            .compactMap { $0.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return CodexAgentScreenContext(
            source: queuedRegions.contains(where: { $0.selection.hasFreehandPath })
                ? "circled screen handoff"
                : "queued screen handoff",
            capturedAt: Date(),
            selectedText: resolveSelectedText(
                from: queuedNotes,
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: attachments
        )
    }

    private func writeNativeComputerUseScreenContext(
        _ capture: OpenClickyComputerUseWindowCapture,
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: capture.window.owner,
            bundleIdentifier: capture.window.bundleIdentifier,
            source: "native_cua_agent_context"
        )
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-cua-swift-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "native CUA Swift focused-window context",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    private func writeBackgroundComputerUseScreenContext(
        _ capture: OpenClickyBackgroundComputerUseWindowCapture,
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: capture.appName,
            bundleIdentifier: capture.bundleID,
            source: "background_computer_use_agent_context"
        )
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-background-computer-use-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "Background Computer Use focused-window context",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    func writeCapturedScreenContext(
        _ captures: [CompanionScreenCapture],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try captures.enumerated().map { index, capture in
            let suffix = capture.isCursorScreen ? "primary" : "secondary-\(index + 1)"
            let fileURL = directory.appendingPathComponent("\(batchID)-\(suffix).jpg", isDirectory: false)
            try capture.imageData.write(to: fileURL, options: .atomic)
            OpenClickyApplicationUsageLogStore.shared.recordApplication(
                name: capture.appName,
                bundleIdentifier: capture.bundleIdentifier,
                source: "agent_screen_context"
            )

            let note = "Image dimensions \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels; display frame x:\(Int(capture.displayFrame.minX)) y:\(Int(capture.displayFrame.minY)) width:\(capture.displayWidthInPoints) height:\(capture.displayHeightInPoints)."

            return CodexAgentScreenContextAttachment(
                label: capture.label,
                fileURL: fileURL,
                note: note
            )
        }

        return CodexAgentScreenContext(
            source: "current desktop screenshot",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: attachments
        )
    }

    private func readSelectedTextForAgentContext(
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) -> String? {
        let selection = readSelectedTextFromPasteboard(
            minimumChangeCount: minimumPasteboardChangeCount,
            allowUnchangedPasteboard: forceClipboardSelection
        )
        guard let selection else { return nil }
        return selection
    }

    private func resolveSelectedText(
        from notes: [String],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) -> String? {
        let cleanedNotes = notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = cleanedNotes.first {
            return first
        }

        return readSelectedTextForAgentContext(
            minimumPasteboardChangeCount: minimumPasteboardChangeCount,
            forceClipboardSelection: forceClipboardSelection
        )
    }

    private func readSelectedTextFromPasteboard(
        minimumChangeCount: Int,
        allowUnchangedPasteboard: Bool = false
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard allowUnchangedPasteboard || currentChangeCount > minimumChangeCount else { return nil }
        guard let rawText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return nil
        }

        let compact = rawText.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(1_500))
    }

    static func shouldForceAgentClipboardSelection(for prompt: String) -> Bool {
        let normalized = prompt
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard normalized.contains("clipboard") || normalized.contains("pasteboard") else {
            return false
        }

        let explicitClipboardUsePattern = #"\b(?:take|pull|use|read|get|grab|fetch|bring|copy|paste|include|attach)\b.{0,40}\b(?:my|the)?\s*(?:clipboard|pasteboard)\b|\bfrom\s+(?:my|the)\s+(?:clipboard|pasteboard)\b"#
        return normalized.range(of: explicitClipboardUsePattern, options: .regularExpression) != nil
    }

    private func createAgentScreenContextDirectory() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("AgentMode", isDirectory: true)
            .appendingPathComponent("ScreenContext", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func agentContextBatchID(date: Date = Date()) -> String {
        let rawID = ISO8601DateFormatter().string(from: date)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = rawID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return sanitized + "-" + String(UUID().uuidString.prefix(8))
    }

    func agentDockTargetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screen(containingOrNearestTo: mouseLocation)
    }

    func pointAtPermissionDragAssistant() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screen(containingOrNearestTo: mouseLocation)
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let assistantCenterY = visibleFrame.minY + max(70, visibleFrame.height * 0.22) + 70
        detectedElementBubbleText = WindowPositionManager.permissionDragAssistantMessage
        detectedElementDisplayFrame = targetScreen.frame
        detectedElementScreenLocation = CGPoint(
            x: visibleFrame.midX - 285,
            y: assistantCenterY
        )
    }

    func showAgentDockWindowNearCurrentScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screen(containingOrNearestTo: mouseLocation)
        guard let targetScreen else { return }
        agentDockWindowManager.show(
            companionManager: self,
            onScreen: targetScreen,
            position: agentParkingPosition
        )
    }

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
    private func clearVoiceResponseCaptionAndInteractiveBubble() {
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
