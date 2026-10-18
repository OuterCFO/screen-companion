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

extension CompanionManager {
    static func clickyAgentInstruction(from transcript: String) -> String? {
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

    static func isClickyInvocationToken(_ normalizedText: String) -> Bool {
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

    static func permissiveAgentInstructionCandidate(
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

    static func shouldInlineDirectFolderOpenFromAgentInstruction(_ instruction: String) -> Bool {
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

    static func diagnosticPasteAgentInstruction(from candidate: String) -> String? {
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

    static func misheardQuestionAgentInstruction(from candidate: String) -> String? {
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

    static func isLikelyAgentToolWorkInstruction(_ instruction: String) -> Bool {
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

    static func noisyAgentTaskCreationInstruction(from candidate: String) -> String? {
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

    static func isMetaAgentRoutingQuestion(_ candidate: String) -> Bool {
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

    static func isIncompleteAgentTaskCreationRequest(from transcript: String) -> Bool {
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

    static func isAgentTaskPlaceholderInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["agent", "task", "job", "session", "agent task", "agent job", "codex task"].contains(normalized)
    }

    static func agentSelectionRequest(from transcript: String) -> OpenClickyAgentSelectionRequest? {
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

    static func cleanedAgentSelectionName(_ rawName: String) -> String {
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

    static func cleanedAgentSelectionFollowUp(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        text = text.replacingOccurrences(
            of: #"(?i)\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?$"#,
            with: "",
            options: .regularExpression
        )
        text = stripMatchingQuotes(from: text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    static func normalizedAgentLookupText(_ value: String) -> String {
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

    static func parallelAgentInstructions(from instruction: String) -> [String] {
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

    static func shouldSplitAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        let explicitSplitPattern = #"\b(?:multiple|several|separate|parallel|independent)\s+(?:background\s+)?(?:agents?|tasks?|workstreams?)\b|\bsplit\b.{0,48}\b(?:agents?|tasks?|workstreams?)\b|\b(?:agents?|tasks?)\b.{0,48}\b(?:separately|in\s+parallel|side\s+by\s+side)\b"#
        if normalized.range(of: explicitSplitPattern, options: .regularExpression) != nil {
            return true
        }

        let enumeratedPattern = #"(?:^|[\n;,.]\s*)(?:first|second|third|fourth|1[.)]|2[.)]|3[.)]|4[.)])\b"#
        return instruction.range(of: enumeratedPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func splitAgentInstructionClauses(_ instruction: String) -> [String] {
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

    static func isAgentRoutingCandidate(_ transcript: String) -> Bool {
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

    static func naturalBackgroundTaskInstruction(from transcript: String) -> String? {
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

    static func cleanedNaturalBackgroundInstruction(from transcript: String) -> String {
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

    static func isRawTransportDiagnosticEvent(_ transcript: String) -> Bool {
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

    static func isLocalFilesystemInspectionRequest(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:what'?s\s+on|what\s+is\s+on|list|show|check|inspect|review|find|search|look\s+at|read|summari[sz]e)\b"#
        let filesystemTargetPattern = #"\b(?:desktop|downloads?|documents?|folder|folders|file|files|directory|directories)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
            && normalized.range(of: filesystemTargetPattern, options: .regularExpression) != nil
    }

    static func isVoiceRouteCapabilityQuestion(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        let routePattern = #"\b(?:voice\s+(?:route|lane|path)|realtime\s+(?:route|voice|path)|without\s+(?:starting\s+)?an?\s+agent|without\s+agent\s+mode|instead\s+of\s+(?:starting\s+)?an?\s+agent)\b"#
        guard normalized.range(of: routePattern, options: .regularExpression) != nil else { return false }

        let questionPattern = #"^(?:can|could|would|will)\s+you\b|^(?:can|could|would)\s+openclicky\b|^is\s+it\s+possible\b|^do\s+you\b|^does\s+openclicky\b"#
        return normalized.range(of: questionPattern, options: .regularExpression) != nil
    }

    static func isGenericWebSearchCapabilityQuestion(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        let pattern = #"^(?:can|could|would|will)\s+you\s+(?:search\s+(?:the\s+)?web|browse\s+(?:the\s+)?web|google|look\s+things?\s+up|look\s+up\s+things?)$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    static func isConversationalPreferenceOrDesignReflection(_ transcript: String) -> Bool {
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

    static func isLikelyPureConversation(_ transcript: String) -> Bool {
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

    static func isInstantVoiceScreenContextRequest(_ transcript: String) -> Bool {
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

    static func containsCodingImplementationCue(_ transcript: String) -> Bool {
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

    static func isLikelyDirectLocalOnlyRequest(_ transcript: String) -> Bool {
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

    static func explicitAgentRouteInstruction(from transcript: String) -> String? {
        if let instruction = explicitNewTaskInstruction(from: transcript) { return instruction }
        if let instruction = agentTaskCreationInstruction(from: transcript) { return instruction }
        if let instruction = clickyAgentInstruction(from: transcript) { return instruction }
        if let instruction = permissiveAgentInstruction(from: transcript) { return instruction }
        return nil
    }

    static func hasAgentWorkVerbAndArtifact(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        let workVerbPattern = #"\b(?:create|make|build|update|change|edit|fix|design|redesign|open|show|preview|pull\s+up|find|save|export|write|review|test|run|stop|ensure|verify|validate|diagnose|investigate|repair|polish|improve|finish|wire|route)\b"#
        let artifactPattern = #"\b(?:form|page|site|website|app|file|document|report|code|repo|repository|github|issue|issues|pull\s+request|pr|folder|version|style|design|panel|overlay|status|progress|comments|logs?|tests?|thinking|calls|ui|volume|slider|control|voice|realtime|computer\s+use|tool|tools|tooling|model|models|routing|route|background|agent\s+mode)\b"#
        return normalized.range(of: workVerbPattern, options: .regularExpression) != nil
            && normalized.range(of: artifactPattern, options: .regularExpression) != nil
    }

    static func isLikelySpecificAgentInstruction(_ instruction: String) -> Bool {
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

    static func isIncompleteLocalAppOpenRequest(from transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)(?:\s+up)?[\s\.\!\?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
    }
}
