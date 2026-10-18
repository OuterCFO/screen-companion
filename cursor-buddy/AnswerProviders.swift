import Foundation

// Adapters that put each existing client behind `AnswerProvider`.
// Clients are reached through closures because `CompanionManager` creates some lazily
// and replaces the Codex voice session when the active task changes.

/// The user's signed-in `claude` CLI; uses their Claude plan.
@MainActor
final class ClaudeCodeAnswerProvider: AnswerProvider {
    let id = "claude_code_cli"
    let billing = AnswerBilling.subscription
    private let client: () -> ClaudeCodeCLIClient?
    init(client: @escaping () -> ClaudeCodeCLIClient?) { self.client = client }

    var isAvailable: Bool { client() != nil }

    func prepare(for model: OpenClickyModelOption) {
        client()?.model = model.id
        client()?.maxOutputTokens = model.maxOutputTokens
    }

    func warmUp(for model: OpenClickyModelOption, systemPrompt: String) {
        client()?.warmUp(systemPrompt: systemPrompt)
    }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard let client = client() else { throw ClaudeCodeCLIProtocol.error("Claude Code is not installed.") }
        return try await client.analyzeImageStreaming(
            images: request.images, systemPrompt: request.systemPrompt, conversationHistory: request.history,
            userPrompt: request.prompt, assistantPrefill: request.assistantPrefill, onTextChunk: onText).text
    }
}

/// Direct Anthropic Messages API with an API key; billed per token.
@MainActor
final class AnthropicAPIAnswerProvider: AnswerProvider {
    let id = "anthropic_api_key"
    let billing = AnswerBilling.perToken
    private let api: () -> ClaudeAPI
    init(api: @escaping () -> ClaudeAPI) { self.api = api }

    var isAvailable: Bool { AppBundleConfiguration.anthropicAPIKey() != nil }

    func prepare(for model: OpenClickyModelOption) {
        api().model = model.id
        api().maxOutputTokens = model.maxOutputTokens
    }

    /// Creating the client starts a TLS warm-up, so a fallback skips the cold handshake.
    func warmUp(for model: OpenClickyModelOption, systemPrompt: String) { _ = api() }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await api().analyzeImageStreaming(
            images: request.images, systemPrompt: request.systemPrompt, conversationHistory: request.history,
            userPrompt: request.prompt, assistantPrefill: request.assistantPrefill, onTextChunk: onText).text
    }
}

/// The local Codex app-server; uses the user's ChatGPT plan.
@MainActor
final class CodexAnswerProvider: AnswerProvider {
    let id = "codex_app_server"
    let billing = AnswerBilling.subscription
    private let session: () -> CodexVoiceSession
    init(session: @escaping () -> CodexVoiceSession) { self.session = session }

    var isAvailable: Bool {
        !CodexRuntimeLocator.codexExecutableCandidates(bundle: .main, fileManager: .default).isEmpty
    }

    /// Realtime speech models stay on the realtime API; Codex serves text models only.
    func supports(_ model: OpenClickyModelOption) -> Bool { !OpenClickyModelCatalog.isSpeechModelID(model.id) }

    func prepare(for model: OpenClickyModelOption) {
        session().model = Self.sessionModelID(for: model)
    }

    /// Codex warm-up opens a thread and sends a short turn, so it runs only at launch or model selection.
    func warmUp(for model: OpenClickyModelOption, systemPrompt: String) {
        session().warmUp(systemPrompt: systemPrompt)
    }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await session().analyzeImageStreaming(
            images: request.images, systemPrompt: request.systemPrompt, conversationHistory: request.history,
            userPrompt: request.prompt, onTextChunk: onText).text
    }

    private static func sessionModelID(for model: OpenClickyModelOption) -> String {
        let analysisID = model.provider == .openAI ? OpenClickyModelCatalog.voiceAnalysisModel(withID: model.id).id : model.id
        return OpenClickyModelCatalog.codexVoiceSessionModel(withID: analysisID).id
    }
}

/// Direct OpenAI Responses API with an API key; billed per token.
@MainActor
final class OpenAIAPIAnswerProvider: AnswerProvider {
    let id = "openai_api_key"
    let billing = AnswerBilling.perToken
    private let api: () -> OpenAIAPI
    init(api: @escaping () -> OpenAIAPI) { self.api = api }

    var isAvailable: Bool { AppBundleConfiguration.openAIAPIKey() != nil }

    func supports(_ model: OpenClickyModelOption) -> Bool { !OpenClickyModelCatalog.isSpeechModelID(model.id) }

    func prepare(for model: OpenClickyModelOption) {
        let analysis = OpenClickyModelCatalog.voiceAnalysisModel(withID: model.id)
        api().model = analysis.id
        api().maxOutputTokens = analysis.maxOutputTokens
    }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await api().analyzeImageStreaming(
            images: request.images, systemPrompt: request.systemPrompt, conversationHistory: request.history,
            userPrompt: request.prompt, onTextChunk: onText).text
    }
}

/// Apple Foundation Models on this Mac; free and text-only.
@MainActor
final class AppleOnDeviceAnswerProvider: AnswerProvider {
    let id = "apple_foundation_models"
    let billing = AnswerBilling.free

    var isAvailable: Bool { AppleFoundationModelsVoiceClient.isAvailable }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await AppleFoundationModelsVoiceClient.analyzeVoiceResponse(
            images: request.images, systemPrompt: request.systemPrompt, conversationHistory: request.history,
            userPrompt: request.prompt, onTextChunk: onText)
    }
}

extension AnswerProviderRegistry {
    /// The shipped provider chains. Each family lists plan or local providers before paid API keys.
    static func standard(claudeCode: @escaping () -> ClaudeCodeCLIClient?, anthropicAPI: @escaping () -> ClaudeAPI,
                         codex: @escaping () -> CodexVoiceSession, openAIAPI: @escaping () -> OpenAIAPI) -> AnswerProviderRegistry {
        let registry = AnswerProviderRegistry()
        let codexProvider = CodexAnswerProvider(session: codex)
        registry.register(.anthropic, [ClaudeCodeAnswerProvider(client: claudeCode), AnthropicAPIAnswerProvider(api: anthropicAPI)])
        registry.register(.openAI, [codexProvider, OpenAIAPIAnswerProvider(api: openAIAPI)])
        registry.register(.codex, [codexProvider])
        registry.register(.apple, [AppleOnDeviceAnswerProvider()])
        // Deepgram is a speech-to-speech agent, not a text answer provider.
        registry.register(.deepgram, [])
        registry.register(.commandLine, [CommandLineAnswerProvider(configs: { CommandLineProviderConfig.load() })])
        return registry
    }
}
