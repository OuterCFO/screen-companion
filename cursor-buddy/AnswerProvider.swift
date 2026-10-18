import Foundation

/// How a provider is paid for. Registration order enforces the money rule:
/// free and subscription providers always come before per-token providers.
nonisolated enum AnswerBilling: Int, Comparable, Sendable {
    case free
    case subscription
    case perToken

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One answer turn: the selected model, the current screens, recent history, and the question.
struct AnswerRequest {
    var model: OpenClickyModelOption
    var images: [(data: Data, label: String)]
    var systemPrompt: String
    var history: [(userPlaceholder: String, assistantResponse: String)]
    var prompt: String
    /// Only providers that support prefill use this; strict response formats pass nil.
    var assistantPrefill: String?
}

/// A backend that turns an `AnswerRequest` into streamed text.
/// Add a provider by conforming to this protocol and registering it in `AnswerProviderRegistry.standard`.
@MainActor
protocol AnswerProvider: AnyObject {
    /// Stable identifier used in logs, for example `claude_code_cli`.
    var id: String { get }
    var billing: AnswerBilling { get }
    /// Whether the provider is installed or configured right now.
    var isAvailable: Bool { get }
    /// Whether this provider can serve the model; defaults to true.
    func supports(_ model: OpenClickyModelOption) -> Bool
    /// Applies the model before a turn; defaults to nothing.
    func prepare(for model: OpenClickyModelOption)
    /// Readies the provider at launch or model selection; defaults to nothing.
    func warmUp(for model: OpenClickyModelOption, systemPrompt: String)
    /// `onText` receives the accumulated text so far.
    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String
}

extension AnswerProvider {
    func supports(_ model: OpenClickyModelOption) -> Bool { true }
    func prepare(for model: OpenClickyModelOption) {}
    func warmUp(for model: OpenClickyModelOption, systemPrompt: String) {}
}

/// Maps each model family to an ordered chain of providers and runs the first one that works.
@MainActor
final class AnswerProviderRegistry {
    private var chains: [OpenClickyModelProvider: [AnswerProvider]] = [:]

    /// Providers are tried in order. A per-token provider may not precede a free or subscription one.
    func register(_ family: OpenClickyModelProvider, _ providers: [AnswerProvider]) {
        precondition(Self.respectsMoneyRule(providers.map(\.billing)),
                     "Per-token providers must come after free and subscription providers for \(family.rawValue).")
        chains[family] = providers
    }

    nonisolated static func respectsMoneyRule(_ billing: [AnswerBilling]) -> Bool {
        zip(billing, billing.dropFirst()).allSatisfy { $0 <= $1 }
    }

    func chain(for model: OpenClickyModelOption) -> [AnswerProvider] {
        (chains[model.provider] ?? []).filter { $0.supports(model) }
    }

    /// The provider that would answer now, for logs and status.
    func primaryProvider(for model: OpenClickyModelOption) -> AnswerProvider? {
        chain(for: model).first(where: \.isAvailable)
    }

    /// Warms only the provider that would answer, so fallbacks spend nothing until needed.
    func warmUp(for model: OpenClickyModelOption, systemPrompt: String) {
        guard let provider = primaryProvider(for: model) else { return }
        provider.prepare(for: model)
        provider.warmUp(for: model, systemPrompt: systemPrompt)
    }

    /// Runs the first available provider; on failure falls through to the next available one.
    /// Cancellation never falls through, so an interrupted answer cannot trigger a paid fallback.
    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let providers = chain(for: request.model).filter(\.isAvailable)
        guard !providers.isEmpty else {
            throw NSError(domain: "AnswerProvider", code: -1, userInfo: [NSLocalizedDescriptionKey:
                "No provider is set up for \(request.model.label). Sign in to its app or CLI, or add an API key in Settings."])
        }
        var lastError: Error?
        for (index, provider) in providers.enumerated() {
            if index > 0, let lastError {
                OpenClickyMessageLogStore.shared.append(lane: "voice", direction: "error", event: "voice.response_fallback", fields: [
                    "from": providers[index - 1].id, "to": provider.id, "model": request.model.id,
                    "error": lastError.localizedDescription
                ])
            }
            do {
                provider.prepare(for: request.model)
                return try await provider.answer(request, onText: onText)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }
}
