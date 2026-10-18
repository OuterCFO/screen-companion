#!/usr/bin/env bash
# Contract tests for the answer-provider registry, Connect sources, and command-line providers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cat > "$OUT/Stubs.swift" <<'SWIFT'
import Foundation
final class OpenClickyMessageLogStore {
    static let shared = OpenClickyMessageLogStore()
    var events: [(String, [String: Any])] = []
    func append(lane: String, direction: String, event: String, fields: [String: Any]) { events.append((event, fields)) }
}
nonisolated enum AppBundleConfiguration { static func openAIAPIKey() -> String? { nil }; static func anthropicAPIKey() -> String? { nil } }
SWIFT

cat > "$OUT/main.swift" <<'SWIFT'
import Foundation

final class StubProvider: AnswerProvider {
    let id: String; let billing: AnswerBilling
    var isAvailable: Bool; var result: Result<String, Error>; var calls = 0; var prepared: [String] = []
    init(_ id: String, _ billing: AnswerBilling, available: Bool = true, result: Result<String, Error>) {
        self.id = id; self.billing = billing; self.isAvailable = available; self.result = result
    }
    func prepare(for model: OpenClickyModelOption) { prepared.append(model.id) }
    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        calls += 1
        let text = try result.get(); onText(text); return text
    }
}
struct Failure: Error {}

@main enum Tests {
    static func main() async throws {
        let model = OpenClickyModelOption(id: "claude-sonnet-5-5", label: "Sonnet 5.5", provider: .anthropic, maxOutputTokens: 64_000)
        func request(_ model: OpenClickyModelOption) -> AnswerRequest {
            AnswerRequest(model: model, images: [], systemPrompt: "s", history: [], prompt: "q", assistantPrefill: nil)
        }

        // Money rule: per-token never precedes plan or free providers
        precondition(AnswerProviderRegistry.respectsMoneyRule([.free, .subscription, .perToken]))
        precondition(AnswerProviderRegistry.respectsMoneyRule([.subscription, .subscription]))
        precondition(!AnswerProviderRegistry.respectsMoneyRule([.perToken, .subscription]))
        print("PASS: money-rule ordering")

        // First available provider answers; unavailable ones are skipped
        let registry = AnswerProviderRegistry()
        let plan = StubProvider("plan", .subscription, available: false, result: .success("plan"))
        let key = StubProvider("key", .perToken, result: .success("key"))
        registry.register(.anthropic, [plan, key])
        precondition(registry.primaryProvider(for: model)?.id == "key")
        let first = try await registry.answer(request(model)) { _ in }
        precondition(first == "key" && plan.calls == 0 && key.prepared == [model.id])
        plan.isAvailable = true
        let second = try await registry.answer(request(model)) { _ in }
        precondition(second == "plan" && key.calls == 1)
        print("PASS: availability and order")

        // Failure falls through to the next provider and is logged; cancellation never does
        plan.result = .failure(Failure())
        let third = try await registry.answer(request(model)) { _ in }
        precondition(third == "key")
        let fallback = OpenClickyMessageLogStore.shared.events.last!
        precondition(fallback.0 == "voice.response_fallback" && fallback.1["from"] as? String == "plan" && fallback.1["to"] as? String == "key")
        plan.result = .failure(CancellationError())
        let keyCalls = key.calls
        do { _ = try await registry.answer(request(model)) { _ in }; preconditionFailure("expected cancellation") }
        catch is CancellationError { precondition(key.calls == keyCalls) }
        key.result = .failure(Failure()); plan.result = .failure(Failure())
        do { _ = try await registry.answer(request(model)) { _ in }; preconditionFailure("expected failure") } catch is Failure {}
        print("PASS: fallback on failure, none on cancellation, last error surfaced")

        // An empty or unknown family explains what to set up
        let apple = OpenClickyModelOption(id: "apple-foundation", label: "Apple", provider: .apple, maxOutputTokens: 1)
        do { _ = try await registry.answer(request(apple)) { _ in }; preconditionFailure("expected error") }
        catch { precondition(error.localizedDescription.contains("No provider is set up for Apple")) }
        print("PASS: unconfigured family error")

        // Command-line provider configuration
        let json = Data(#"""
        [{"id": "gemini", "label": "Gemini CLI", "executable": "gemini", "arguments": ["-p", "{prompt}"]},
         {"id": "gemini", "label": "Duplicate", "executable": "x", "arguments": []},
         {"id": "bad id/..", "label": "Bad", "executable": "x", "arguments": []},
         {"id": "llm", "label": "llm", "executable": "", "arguments": []},
         {"id": "ollama", "label": "Ollama", "executable": "/usr/local/bin/ollama", "arguments": ["run", "llava", "{images}"], "timeoutSeconds": 30}]
        """#.utf8)
        let configs = CommandLineProviderConfig.decode(json)
        precondition(configs.map(\.id) == ["gemini", "ollama"] && configs[1].timeoutSeconds == 30)
        precondition(CommandLineProviderConfig.decode(Data("not json".utf8)).isEmpty)
        precondition(configs[0].modelOption.id == "cli:gemini" && configs[0].modelOption.provider == .commandLine)
        let argumentPrompt = configs[0].invocation(prompt: "hi there", imagePaths: ["/a.png"])
        precondition(argumentPrompt.arguments == ["-p", "hi there"] && argumentPrompt.standardInput == nil && !configs[0].sendsImages)
        let stdinPrompt = configs[1].invocation(prompt: "hi", imagePaths: ["/a.png", "/b.jpg"])
        precondition(stdinPrompt.arguments == ["run", "llava", "/a.png", "/b.jpg"] && stdinPrompt.standardInput == "hi")
        let textOnly = CommandLineProviderConfig.flattenedPrompt(systemPrompt: "rules", history: [], imageLabels: ["screen0"], prompt: "q", sendsImages: false)
        precondition(textOnly.contains("Screenshots are not available") && textOnly.hasSuffix("q") && !textOnly.contains("Screen context"))
        let withImages = CommandLineProviderConfig.flattenedPrompt(systemPrompt: "rules", history: [], imageLabels: ["screen0"], prompt: "q", sendsImages: true)
        precondition(withImages.contains("Screen context:\n1. screen0") && !withImages.contains("not available"))
        print("PASS: command-line config validation, argument and stdin prompts, image placeholders")

        // Real processes: argument prompt, stdin prompt, failure detail, timeout, cancellation
        let tmp = FileManager.default.temporaryDirectory
        var chunks: [String] = []
        let echoed = try await CommandLineRun.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "world"],
            standardInput: nil, workingDirectory: tmp, timeout: .seconds(10)) { chunks.append($0) }
        precondition(echoed == "hello world" && !chunks.isEmpty)
        let catted = try await CommandLineRun.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            standardInput: "from stdin\n", workingDirectory: tmp, timeout: .seconds(10)) { _ in }
        precondition(catted == "from stdin")
        do {
            _ = try await CommandLineRun.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo nope >&2; exit 3"],
                standardInput: nil, workingDirectory: tmp, timeout: .seconds(10)) { _ in }
            preconditionFailure("expected failure")
        } catch { precondition(error.localizedDescription.contains("status 3") && error.localizedDescription.contains("nope")) }
        let started = Date()
        do {
            _ = try await CommandLineRun.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                standardInput: nil, workingDirectory: tmp, timeout: .milliseconds(300)) { _ in }
            preconditionFailure("expected timeout")
        } catch { precondition(error.localizedDescription.contains("did not finish") && Date().timeIntervalSince(started) < 3) }
        let task = Task { try await CommandLineRun.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                                       standardInput: nil, workingDirectory: tmp, timeout: .seconds(10)) { _ in } }
        try await Task.sleep(for: .milliseconds(200)); task.cancel()
        do { _ = try await task.value; preconditionFailure("expected cancellation") } catch is CancellationError {}
        print("PASS: command-line runs stream output, report failures, time out, and cancel")
        exit(0)
    }
}
SWIFT

xcrun swiftc -parse-as-library -default-isolation MainActor -target "$(uname -m)-apple-macos26.0" -o "$OUT/answer_provider_tests" \
  "$OUT/Stubs.swift" "$OUT/main.swift" \
  "$ROOT/cursor-buddy/AnswerProvider.swift" \
  "$ROOT/cursor-buddy/OpenClickyModelCatalog.swift" \
  "$ROOT/cursor-buddy/CommandLineProviderConfig.swift" \
  "$ROOT/cursor-buddy/CommandLineProvider.swift" \
  "$ROOT/cursor-buddy/ClaudeCodeCLIProtocol.swift"
"$OUT/answer_provider_tests"
