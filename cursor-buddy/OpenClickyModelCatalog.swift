import Foundation

nonisolated enum OpenClickyModelProvider: String, Equatable {
    case apple
    case anthropic
    case openAI
    case codex
    /// A user-configured command-line tool; see `CommandLineProviderConfig`.
    case commandLine

    var displayName: String {
        switch self {
        case .apple:
            return "Apple"
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        case .codex:
            return "Codex"
        case .commandLine:
            return "Command line"
        }
    }

    /// Coarse family used by the bubble / notch provider selector.
    /// Command-line tools stay outside this three-way switch.
    var voiceBackendFamily: OpenClickyVoiceBackendFamily? {
        switch self {
        case .apple:
            return .apple
        case .anthropic:
            return .claude
        case .codex:
            return .codex
        case .openAI:
            return .codex
        case .commandLine:
            return nil
        }
    }
}

/// Terminal-first voice backend family: Apple on-device, local Codex, or Claude Agent SDK.
nonisolated enum OpenClickyVoiceBackendFamily: String, CaseIterable, Equatable, Sendable {
    case apple
    case codex
    case claude

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var shortLabel: String {
        switch self {
        case .apple: return "A"
        case .codex: return "X"
        case .claude: return "C"
        }
    }

    /// Default catalog model id when the user picks this family in the bubble selector.
    var defaultModelID: String {
        switch self {
        case .apple:
            return OpenClickyModelCatalog.appleFoundationModelID
        case .codex:
            return OpenClickyModelCatalog.defaultCodexActionsModelID
        case .claude:
            return OpenClickyModelCatalog.defaultAnthropicResponseModelID
        }
    }
}

nonisolated struct OpenClickyModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let provider: OpenClickyModelProvider
    /// Published maximum generated output tokens for this model.
    /// For Anthropic this maps to `max_tokens`; for OpenAI Responses this maps to `max_output_tokens`.
    ///
    /// Voice responses must not carry a short-form cap here: the prompt
    /// already asks for concise spoken replies by default, but if the user
    /// asks for a deeper answer the TTS pipeline should be allowed to keep
    /// generating rather than truncating at an artificial "spoken" budget.
    let maxOutputTokens: Int
}

nonisolated enum OpenClickyModelCatalog {
    /// Fast conversational responder. Used for the always-on voice loop —
    /// hears the user, routes direct computer-use locally, and delegates
    /// background work to the configured Codex model.
    static let defaultVoiceResponseModelID = defaultCodexActionsModelID
    /// Sonnet is on every Claude plan; Fable needs usage credits on some plans.
    static let defaultAnthropicResponseModelID = "claude-sonnet-5-5"
    static let defaultCodexActionsModelID = "gpt-6-luna"
    /// On-device Apple Foundation Models (macOS 26+ / Apple Intelligence).
    static let appleFoundationModelID = "apple-foundation"
    /// Text/vision model used for screenshots, attachments, and Codex fallback.
    static let defaultVoiceAnalysisModelID = defaultCodexActionsModelID
    /// Heavier model used when the voice responder delegates a coding/agent task.
    /// Coding work goes here; the voice path stays on the fast model.
    static let defaultDelegationModelID = "claude-sonnet-5-5"
    static let defaultComputerUseModelID = defaultCodexActionsModelID

    /// Resolves the delegation model — falls back to a sensible coder
    /// when the user hasn't picked one explicitly.
    static func delegationModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if let match = voiceResponseModels.first(where: { $0.id == resolved }) {
                return match
            }
        }
        return voiceResponseModel(withID: defaultDelegationModelID)
    }

    /// Command-line tools from the user's configuration file, read once at launch.
    static let commandLineModels: [OpenClickyModelOption] = CommandLineProviderConfig.load().map(\.modelOption)

    static let voiceResponseModels: [OpenClickyModelOption] = builtInVoiceResponseModels + commandLineModels

    static let builtInVoiceResponseModels: [OpenClickyModelOption] = [
        // Voice turns should still be concise by prompt, but never by a
        // hard generation ceiling. Long spoken explanations can stream
        // sentence-by-sentence through TTS without being cut off.
        OpenClickyModelOption(id: appleFoundationModelID, label: "Apple On-Device", provider: .apple, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-fable-5-1", label: "Fable 5.1", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-sonnet-5-5", label: "Sonnet 5.5", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-5-5", label: "Opus 5.5", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-6-luna", label: "GPT-6 Luna", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-luna", label: "GPT-5.6 Luna", provider: .openAI, maxOutputTokens: 128_000)
    ]

    static let responseVoiceModels: [OpenClickyModelOption] = voiceResponseModels

    static let computerUseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-5-5", label: "Sonnet 5.5", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-5-5", label: "Opus 5.5", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-6-luna", label: "GPT-6 Luna", provider: .codex, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol", provider: .codex, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra", provider: .codex, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-luna", label: "GPT-5.6 Luna", provider: .codex, maxOutputTokens: 128_000)
    ]

    static let codexActionsModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "gpt-6-luna", label: "GPT-6 Luna", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.6-luna", label: "GPT-5.6 Luna", provider: .openAI, maxOutputTokens: 128_000)
    ]
    // Local MLX models are intentionally NOT offered for Agent Mode: the local
    // endpoint (mlx_lm at 127.0.0.1:32124) only speaks /v1/chat/completions,
    // but Codex requires the Responses API, so routing agents there 404s on
    // /v1/responses. Keep agents on real cloud providers.

    /// Maps retired / alias model IDs onto the currently offered catalog IDs.
    static func normalizedModelID(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultVoiceResponseModelID }
        switch trimmed.lowercased() {
        // Realtime speech and Deepgram voice-agent models were removed; saved choices use the text default.
        case "gpt-realtime-2", "gpt-realtime-2.0", "gpt-realtime-2-mini", "gpt-realtime-2.1-mini", "gpt-realtime-2.1",
             "gpt-realtime-1.5", "deepgram-voice-agent":
            return defaultVoiceResponseModelID
        // Earlier builds saved short IDs that neither the Claude CLI nor the API resolves.
        case "fable", "fable-5", "claude-fable-5":
            return "claude-fable-5-1"
        case "claude-haiku-4-5", "claude-haiku-4-6", "haiku-5":
            return defaultAnthropicResponseModelID
        case "claude-sonnet-4-6", "sonnet", "sonnet-5", "claude-sonnet-5":
            return "claude-sonnet-5-5"
        case "claude-opus-4-6", "opus", "opus-5", "claude-opus-5":
            return "claude-opus-5-5"
        case "gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2":
            return defaultCodexActionsModelID
        case "gpt-5.4-mini":
            return "gpt-5.6-luna"
        default:
            return trimmed
        }
    }

    static func voiceResponseModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        if let match = responseVoiceModels.first(where: { $0.id == resolved }) {
            return match
        }
        return responseVoiceModels.first { $0.id == defaultVoiceResponseModelID } ?? voiceResponseModels[0]
    }

    static func voiceAnalysisModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if let match = voiceResponseModels.first(where: { $0.id == resolved }) {
                return match
            }
        }
        if let match = voiceResponseModels.first(where: { $0.id == defaultVoiceAnalysisModelID }) {
            return match
        }
        return voiceResponseModels[0]
    }

    static func codexVoiceSessionModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if let match = codexActionsModels.first(where: { $0.id == resolved }) {
                return match
            }
        }

        let analysisModel = voiceAnalysisModel(withID: modelID)
        if let match = codexActionsModels.first(where: { $0.id == analysisModel.id }) {
            return match
        }

        return codexActionsModels.first { $0.id == defaultCodexActionsModelID } ?? codexActionsModels[0]
    }

    static func computerUseModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        return computerUseModels.first { $0.id == resolved }
            ?? computerUseModels.first { $0.id == defaultComputerUseModelID }
            ?? computerUseModels[0]
    }

    /// Background agent models: Codex models run in Codex, Claude models in the user's Claude Code CLI.
    static let claudeAgentModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-5-5", label: "Sonnet 5.5 (Claude Code)", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-5-5", label: "Opus 5.5 (Claude Code)", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "claude-fable-5-1", label: "Fable 5.1 (Claude Code)", provider: .anthropic, maxOutputTokens: 64_000)
    ]

    static let agentModels: [OpenClickyModelOption] = codexActionsModels + claudeAgentModels

    static func agentModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        return agentModels.first { $0.id == resolved } ?? codexActionsModel(withID: resolved)
    }

    static func codexActionsModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        return codexActionsModels.first { $0.id == resolved }
            ?? codexActionsModels.first { $0.id == defaultCodexActionsModelID }
            ?? codexActionsModels[0]
    }
}
