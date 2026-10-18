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
    static func webOpenRequest(from transcript: String) -> OpenClickyWebOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let browserNavigationPatterns: [(pattern: String, browserGroup: Int, targetGroup: Int)] = [
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to)\s+(?:the\s+)?((?:google\s+)?chrome|safari)\s*(?:,|\band\b|\bthen\b)?\s*(?:go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show|open)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                1,
                2
            ),
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show|open)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?\s+(?:in|on|using|with)\s+(?:the\s+)?((?:google\s+)?chrome|safari)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                2,
                1
            )
        ]

        for browserNavigationPattern in browserNavigationPatterns {
            guard let regex = try? NSRegularExpression(pattern: browserNavigationPattern.pattern) else { continue }
            let range = NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
            guard let match = regex.firstMatch(in: trimmedTranscript, range: range),
                  let browserRange = Range(match.range(at: browserNavigationPattern.browserGroup), in: trimmedTranscript),
                  let targetRange = Range(match.range(at: browserNavigationPattern.targetGroup), in: trimmedTranscript) else {
                continue
            }

            let rawBrowser = String(trimmedTranscript[browserRange])
            let browserAppName = normalizedApplicationName(from: rawBrowser)
            guard ["Google Chrome", "Safari"].contains(browserAppName) else { continue }

            let rawTarget = String(trimmedTranscript[targetRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
            guard let url = normalizedWebOpenURL(from: rawTarget) else { continue }
            return OpenClickyWebOpenRequest(
                url: url,
                displayName: displayNameForWebOpenTarget(rawTarget, url: url),
                instruction: trimmedTranscript,
                browserAppName: browserAppName
            )
        }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:the\s+)?(.+?)\s+(?:website|web\s+site|webpage|web\s+page|url|site)[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
            guard let match = regex.firstMatch(in: trimmedTranscript, range: range),
                  let targetRange = Range(match.range(at: 1), in: trimmedTranscript) else {
                continue
            }

            let rawTarget = String(trimmedTranscript[targetRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
            guard let url = normalizedWebOpenURL(from: rawTarget) else { continue }
            return OpenClickyWebOpenRequest(
                url: url,
                displayName: displayNameForWebOpenTarget(rawTarget, url: url),
                instruction: trimmedTranscript,
                browserAppName: nil
            )
        }

        return nil
    }

    static func normalizedWebOpenURL(from rawTarget: String) -> URL? {
        let trimmed = rawTarget.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if lowered.hasPrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }
        if lowered.range(of: #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\b"#, options: .regularExpression) != nil {
            return URL(string: "https://\(lowered)")
        }

        return nil
    }

    static func displayNameForWebOpenTarget(_ rawTarget: String, url: URL) -> String {
        let cleaned = rawTarget.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
        if !cleaned.isEmpty {
            return cleaned
        }
        return url.host ?? url.absoluteString
    }

    static func compositeAppActionRequest(from transcript: String) -> OpenClickyCompositeAppActionRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }
        guard !isExplicitAgentRoutingCandidate(candidate) else { return nil }

        let patterns: [(pattern: String, requiresKnownApp: Bool, requiresActionVerb: Bool)] = [
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)\s+(?:and|then)\s+(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                false,
                false
            ),
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)\s+to\s+(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                false,
                false
            ),
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+?)\s+(?:and|then)\s+(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                true,
                true
            )
        ]

        for compositePattern in patterns {
            let pattern = compositePattern.pattern
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let appRange = Range(match.range(at: 1), in: candidate),
                  let actionRange = Range(match.range(at: 2), in: candidate) else {
                continue
            }

            let rawAppName = String(candidate[appRange])
            let actionText = cleanedCompositeAppActionText(String(candidate[actionRange]))
            let appName = normalizedApplicationName(from: rawAppName)
            guard !appName.isEmpty,
                  !actionText.isEmpty,
                  !isContaminatedCompositeAppName(rawAppName),
                  (!compositePattern.requiresKnownApp || isKnownBareLocalApplicationName(appName)),
                  (!compositePattern.requiresActionVerb || hasDirectCompositeActionVerb(actionText)),
                  !isReservedAgentOpenTarget(rawAppName),
                  !isLocalAppOpenPlaceholder(appName),
                  !isLikelyFileOrFolderOpenTarget(rawAppName),
                  !isLikelyWebOpenTarget(rawAppName),
                  !isLikelyBrowserNavigationAction(actionText) else {
                continue
            }

            return OpenClickyCompositeAppActionRequest(
                appName: appName,
                actionText: actionText,
                instruction: candidate
            )
        }

        return nil
    }

    static func cleanedCompositeAppActionText(_ rawActionText: String) -> String {
        var actionText = rawActionText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
        actionText = actionText.replacingOccurrences(
            of: #"(?i)^(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?"#,
            with: "",
            options: .regularExpression
        )
        return actionText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
    }

    static func isLikelyBrowserNavigationAction(_ actionText: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(actionText)
        let pattern = #"\b(?:go\s+to|navigate\s+to|browse\s+to|visit|open\s+(?:the\s+)?(?:website|web\s*site|webpage|web\s*page|url|site))\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    static func isContaminatedCompositeAppName(_ rawAppName: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(rawAppName)
        let pattern = #"\b(?:and|then)\s+(?:go|navigate|browse|visit|open|play|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose)\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    static func hasDirectCompositeActionVerb(_ actionText: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(actionText)
        let pattern = #"^(?:play|pause|resume|skip|next|previous|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose|go\s+to|navigate\s+to|browse\s+to|visit)\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    static func compositeAppSearchQuery(from actionText: String) -> String? {
        let candidate = cleanedCompositeAppActionText(actionText)
        let patterns = [
            #"(?i)^\s*(?:search|find|look\s+up)\s+(?:for\s+)?(.+?)(?:\s+in\s+(?:the\s+)?(?:app|application|window))?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let queryRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let query = cleanedCompositeActionPayload(String(candidate[queryRange]))
            guard !query.isEmpty else { continue }
            return query
        }

        return nil
    }

    static func spotifyPlaybackQuery(from actionText: String) -> String? {
        let candidate = cleanedCompositeAppActionText(actionText)
        let patterns = [
            #"(?i)^\s*(?:play|put\s+on)\s+(?:the\s+)?(?:(?:song|track|album|artist)\s+)?(.+?)(?:\s+on\s+spotify)?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let queryRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let query = cleanedCompositeActionPayload(String(candidate[queryRange]))
            let normalized = SpokenText.normalizedSpokenCommandText(query)
            guard !query.isEmpty,
                  !["something", "music", "a song", "the song", "anything", "spotify"].contains(normalized) else {
                continue
            }
            return query
        }

        return nil
    }

    static func standaloneSpotifyPlaybackRequest(from transcript: String) -> OpenClickyCompositeAppActionRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty,
              !isExplicitAgentRoutingCandidate(candidate),
              compositeAppActionRequest(from: candidate) == nil else {
            return nil
        }

        let actionText = cleanedCompositeAppActionText(candidate)
        if let controlAction = spotifyPlaybackControlAction(from: actionText),
           !spotifyPlaybackControlRequiresExplicitSpotifyContext(controlAction) || hasSpotifyContext(candidate) {
            return OpenClickyCompositeAppActionRequest(
                appName: "Spotify",
                actionText: actionText,
                instruction: candidate
            )
        }

        if let query = spotifyPlaybackQuery(from: actionText),
           !isAmbiguousStandaloneSpotifyPlaybackQuery(query) {
            return OpenClickyCompositeAppActionRequest(
                appName: "Spotify",
                actionText: actionText,
                instruction: candidate
            )
        }

        return nil
    }

    static func isAmbiguousStandaloneSpotifyPlaybackQuery(_ query: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(query)
        let ambiguousTargets: Set<String> = [
            "it",
            "that",
            "this",
            "video",
            "the video",
            "movie",
            "the movie",
            "episode",
            "the episode",
            "clip",
            "the clip",
            "youtube",
            "youtube video"
        ]
        return ambiguousTargets.contains(normalized)
    }

    static func systemVolumeControlAction(from transcript: String) -> OpenClickySystemVolumeControlAction? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty,
              !isExplicitAgentRoutingCandidate(candidate),
              !hasSpotifyContext(candidate),
              compositeAppActionRequest(from: candidate) == nil else {
            return nil
        }

        let normalized = SpokenText.normalizedSpokenCommandText(cleanedCompositeAppActionText(candidate))
        if let volumePercent = systemVolumePercent(fromNormalizedControlText: normalized) {
            return OpenClickySystemVolumeControlAction(.setVolume, volumePercent: volumePercent)
        }

        switch normalized {
        case "volume up", "system volume up", "turn volume up", "turn system volume up",
             "increase volume", "increase system volume", "raise volume", "raise system volume",
             "turn it up", "louder", "make it louder":
            return OpenClickySystemVolumeControlAction(.volumeUp)
        case "volume down", "system volume down", "turn volume down", "turn system volume down",
             "decrease volume", "decrease system volume", "lower volume", "lower system volume",
             "turn it down", "quieter", "make it quieter":
            return OpenClickySystemVolumeControlAction(.volumeDown)
        case "mute", "mute volume", "mute system volume", "mute the volume", "mute the system volume",
             "turn mute on", "turn system mute on":
            return OpenClickySystemVolumeControlAction(.mute)
        default:
            return nil
        }
    }

    static func systemVolumePercent(fromNormalizedControlText normalized: String) -> Int? {
        let patterns = [
            #"^(?:set\s+)?(?:system\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:turn\s+)?(?:system\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:set\s+)?(?:system\s+)?sound\s+volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  let percentRange = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[percentRange]) else {
                continue
            }
            return min(100, max(0, value))
        }
        return nil
    }

    static func spotifyPlaybackControlRequiresExplicitSpotifyContext(_ action: OpenClickySpotifyPlaybackControlAction) -> Bool {
        switch action.kind {
        case .volumeUp, .volumeDown, .volumeMute, .volumeSet:
            return true
        default:
            return false
        }
    }

    static func hasSpotifyContext(_ transcript: String) -> Bool {
        SpokenText.normalizedSpokenCommandText(transcript).range(
            of: #"\bspotify\b"#,
            options: .regularExpression
        ) != nil
    }

    static func spotifyPlaybackControlAction(from actionText: String) -> OpenClickySpotifyPlaybackControlAction? {
        var normalized = SpokenText.normalizedSpokenCommandText(cleanedCompositeAppActionText(actionText))
        normalized = normalized.replacingOccurrences(
            of: #"\s+(?:(?:in|on)\s+)?spotify$"#,
            with: "",
            options: .regularExpression
        )
        if let volumePercent = spotifyVolumePercent(fromNormalizedControlText: normalized) {
            return OpenClickySpotifyPlaybackControlAction(.volumeSet, volumePercent: volumePercent)
        }
        switch normalized {
        case "play", "resume", "start playing", "keep playing",
             "play music", "play some music", "play something", "play anything",
             "put on music", "put some music on", "put anything on":
            return OpenClickySpotifyPlaybackControlAction(.play)
        case "pause", "stop", "stop playing":
            return OpenClickySpotifyPlaybackControlAction(.pause)
        case "play pause", "playpause", "toggle playback":
            return OpenClickySpotifyPlaybackControlAction(.playPause)
        case "skip", "next", "next song", "next track":
            return OpenClickySpotifyPlaybackControlAction(.next)
        case "back", "go back", "previous", "previous song", "previous track", "last song", "last track":
            return OpenClickySpotifyPlaybackControlAction(.previous)
        case "shuffle", "shuffle on", "turn shuffle on", "enable shuffle", "shuffle music":
            return OpenClickySpotifyPlaybackControlAction(.shuffleOn)
        case "shuffle off", "turn shuffle off", "disable shuffle":
            return OpenClickySpotifyPlaybackControlAction(.shuffleOff)
        case "repeat", "repeat on", "repeat track", "repeat song", "repeat one", "turn repeat on", "enable repeat", "loop", "loop on":
            return OpenClickySpotifyPlaybackControlAction(.repeatOn)
        case "repeat off", "turn repeat off", "disable repeat", "loop off":
            return OpenClickySpotifyPlaybackControlAction(.repeatOff)
        case "volume up", "spotify volume up", "turn volume up", "turn spotify volume up", "increase volume", "increase spotify volume", "raise volume", "raise spotify volume", "turn it up", "louder", "make it louder":
            return OpenClickySpotifyPlaybackControlAction(.volumeUp)
        case "volume down", "spotify volume down", "turn volume down", "turn spotify volume down", "decrease volume", "decrease spotify volume", "lower volume", "lower spotify volume", "turn it down", "quieter", "make it quieter":
            return OpenClickySpotifyPlaybackControlAction(.volumeDown)
        case "mute", "mute volume", "mute spotify":
            return OpenClickySpotifyPlaybackControlAction(.volumeMute)
        default:
            return nil
        }
    }

    static func spotifyVolumePercent(fromNormalizedControlText normalized: String) -> Int? {
        let patterns = [
            #"^(?:set\s+)?(?:spotify\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:turn\s+)?(?:spotify\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:set\s+)?(?:spotify\s+)?sound\s+volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  let percentRange = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[percentRange]) else {
                continue
            }
            return min(100, max(0, value))
        }
        return nil
    }

    static func spotifySearchURL(for query: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard !encoded.isEmpty else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }

    static func spotifySearchPlayExecutionMethod(for backend: OpenClickyComputerUseBackendID) -> String {
        switch backend {
        case .backgroundComputerUse:
            return "NSWorkspace.open_spotify_uri + BackgroundComputerUse /v1/press_key + AppleScript play retry + playback verification"
        case .nativeSwift:
            return "NSWorkspace.open_spotify_uri + OpenClickyNativeComputerUseController.pressKey + AppleScript play retry + playback verification"
        }
    }

    static func cleanedCompositeActionPayload(_ rawPayload: String) -> String {
        var payload = rawPayload.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
        payload = stripMatchingQuotes(from: payload)
        payload = payload.replacingOccurrences(
            of: #"(?i)\s+(?:please|for\s+me)$"#,
            with: "",
            options: .regularExpression
        )
        return payload.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
    }

    static func compositeAppActionAgentInstruction(from request: OpenClickyCompositeAppActionRequest) -> String {
        "Use OpenClicky's available app automation, installed skills/connectors, or selected computer-use path to complete this full app action. Open \(request.appName) if needed, then perform this action in \(request.appName): \(request.actionText). Do not report success after only opening the app. Original request: \(request.instruction)"
    }

    static func localAppOpenRequest(from transcript: String) -> OpenClickyAppOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }
        guard !isExplicitAgentRoutingCandidate(trimmedTranscript) else { return nil }
        guard compositeAppActionRequest(from: trimmedTranscript) == nil else { return nil }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+|you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
            in: trimmedTranscript,
            range: NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
           ),
           let targetRange = Range(match.range(at: 1), in: trimmedTranscript) {
            let rawTarget = String(trimmedTranscript[targetRange])
            let cleanedTarget = cleanedApplicationOpenTarget(rawTarget)
            let normalizedTarget = normalizedApplicationName(from: cleanedTarget)
            guard !normalizedTarget.isEmpty,
                  !isReservedAgentOpenTarget(cleanedTarget),
                  !isLocalAppOpenPlaceholder(normalizedTarget),
                  !isLikelyFileOrFolderOpenTarget(cleanedTarget),
                  !isLikelyWebOpenTarget(cleanedTarget) else {
                return nil
            }

            return OpenClickyAppOpenRequest(
                appName: normalizedTarget,
                instruction: "Open \(normalizedTarget)."
            )
        }

        return bareLocalAppOpenRequest(fromNormalizedCandidate: trimmedTranscript)
    }

    static func bareLocalAppOpenRequest(from transcript: String) -> OpenClickyAppOpenRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        return bareLocalAppOpenRequest(fromNormalizedCandidate: candidate)
    }

    static func bareLocalAppOpenRequest(fromNormalizedCandidate candidate: String) -> OpenClickyAppOpenRequest? {
        let rawTarget = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        guard !rawTarget.isEmpty,
              !isExplicitAgentRoutingCandidate(rawTarget),
              !isReservedAgentOpenTarget(rawTarget),
              !isLikelyFileOrFolderOpenTarget(rawTarget),
              !isLikelyWebOpenTarget(rawTarget) else {
            return nil
        }

        let normalizedTarget = normalizedApplicationName(from: rawTarget)
        guard isKnownBareLocalApplicationName(normalizedTarget),
              !isLocalAppOpenPlaceholder(normalizedTarget) else {
            return nil
        }

        return OpenClickyAppOpenRequest(
            appName: normalizedTarget,
            instruction: "Open \(normalizedTarget)."
        )
    }

    static func isKnownBareLocalApplicationName(_ appName: String) -> Bool {
        switch appName {
        case "Google Chrome",
            "Safari",
            "Xcode",
            "Terminal",
            "Ghostty",
            "Finder",
            "System Settings",
            "Mail",
            "Messages",
            "Notes",
            "Reminders",
            "Calendar",
            "Slack",
            "Spotify",
            "Cursor",
            "GitHub Desktop",
            "Codex":
            return true
        default:
            return false
        }
    }

    static func reminderAddRequest(from transcript: String) -> OpenClickyReminderAddRequest? {
        guard logEvidenceAnalysisInstruction(from: transcript) == nil else { return nil }

        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = SpokenText.normalizedSpokenCommandText(candidate)
        let mentionsReminders = normalizedCandidate.contains("reminder")
            || normalizedCandidate.contains("reminders")
            || normalizedCandidate.contains("todo")
            || normalizedCandidate.contains("to do")
            || normalizedCandidate.contains("task")
        guard mentionsReminders else { return nil }

        let hasAddAction = normalizedCandidate.contains("add")
            || normalizedCandidate.contains("create")
            || normalizedCandidate.contains("make")
            || normalizedCandidate.contains("set")
            || normalizedCandidate.hasPrefix("remind me")
        guard hasAddAction else { return nil }

        let titlePatterns = [
            #"(?i)\b(?:just\s+)?(?:call\s+it|called|named|saying|that\s+says|with\s+title)\s+(.+?)\s*$"#,
            #"(?i)^\s*remind\s+me\s+to\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:add|create|make|set)\s+(?:a\s+|an\s+|the\s+)?(?:new\s+|test\s+)?(?:reminder|task|todo|to-do)(?:\s+(?:in|to|on)\s+(?:my\s+)?(?:apple\s+)?reminders?(?:\s+app)?)?(?:\s+(?:to|for)\s+)?(.+?)\s*$"#,
            #"(?i)^\s*(?:add|create|make)\s+(.+?)\s+(?:to|in|on)\s+(?:my\s+)?(?:apple\s+)?reminders?(?:\s+app)?\s*$"#
        ]

        for pattern in titlePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let titleRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let title = cleanedReminderTitle(String(candidate[titleRange]))
            guard !title.isEmpty, !isReminderTitlePlaceholder(title) else { continue }
            return OpenClickyReminderAddRequest(title: title, instruction: candidate)
        }

        return nil
    }

    static func reminderCountRequest(from transcript: String) -> OpenClickyReminderCountRequest? {
        guard logEvidenceAnalysisInstruction(from: transcript) == nil else { return nil }

        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = SpokenText.normalizedSpokenCommandText(candidate)
        guard normalizedCandidate.contains("reminder")
            || normalizedCandidate.contains("reminders")
            || normalizedCandidate.contains("todo")
            || normalizedCandidate.contains("to do")
            || normalizedCandidate.contains("tasks") else {
            return nil
        }

        let countSignals = [
            "how many",
            "count",
            "number of",
            "what reminders",
            "what tasks",
            "what todos",
            "do i have"
        ]
        guard countSignals.contains(where: { normalizedCandidate.contains($0) }) else { return nil }

        return OpenClickyReminderCountRequest(instruction: candidate)
    }

    static func messagesSearchRequest(from transcript: String) -> OpenClickyMessagesSearchRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = SpokenText.normalizedSpokenCommandText(candidate)
        guard normalizedCandidate.contains("message") || normalizedCandidate.contains("messages") else {
            return nil
        }
        guard normalizedCandidate.contains("from") || normalizedCandidate.contains("with") else {
            return nil
        }

        let patterns = [
            #"(?i)\bmessages?\s+from\s+(.+?)(?:\s+(?:today|this\s+morning|this\s+afternoon|this\s+evening|tonight|yesterday))?[\.\!\?]*\s*$"#,
            #"(?i)\bmessages?\s+with\s+(.+?)(?:\s+(?:today|this\s+morning|this\s+afternoon|this\s+evening|tonight|yesterday))?[\.\!\?]*\s*$"#,
            #"(?i)\bfrom\s+(.+?)\s+(?:in|on)\s+messages?[\.\!\?]*\s*$"#,
            #"(?i)\bfrom\s+(.+?)(?:\s+(?:today|this\s+morning|this\s+afternoon|this\s+evening|tonight|yesterday))[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let personRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let personName = cleanedMessagesSearchName(String(candidate[personRange]))
            guard !personName.isEmpty, !isMessagesSearchPlaceholder(personName) else { continue }
            return OpenClickyMessagesSearchRequest(personName: personName, instruction: candidate)
        }

        return nil
    }

    static func localFolderOpenRequest(from transcript: String) -> OpenClickyFolderOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let normalizedTranscript = trimmedTranscript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard Self.containsFolderOpenVerb(normalizedTranscript),
              !Self.isBlockedFolderOpenShortcutContext(normalizedTranscript) else {
            return nil
        }

        let sourceFolderTerms = [
            "source code folder",
            "source folder",
            "code folder",
            "project folder",
            "openclicky folder",
            "open clicky folder",
            "clicky folder",
            "repo folder",
            "repository folder",
            "openclicky source",
            "open clicky source"
        ]

        if sourceFolderTerms.contains(where: { normalizedTranscript.contains($0) }),
           let sourceURL = existingOpenClickySourceDirectoryURL() {
            return OpenClickyFolderOpenRequest(
                url: sourceURL,
                displayName: "the source code folder",
                instruction: trimmedTranscript
            )
        }

        if let rememberedShortcut = OpenClickyDirectActionMemoryStore.shared.folderShortcut(matching: normalizedTranscript) {
            return OpenClickyFolderOpenRequest(
                url: rememberedShortcut.url,
                displayName: rememberedShortcut.displayName,
                instruction: trimmedTranscript
            )
        }

        return nil
    }

    static func containsFolderOpenVerb(_ normalizedTranscript: String) -> Bool {
        let commandPattern = #"^(?:(?:can|could|would|will)\s+you\s+|you\s+|please\s+|now\s+)*(?:open|show|reveal|switch\s+to|bring\s+up|pull\s+up|go\s+into|go\s+in|go\s+to|navigate\s+to|inside)\b"#
        return normalizedTranscript.range(of: commandPattern, options: .regularExpression) != nil
    }

    static func isBlockedFolderOpenShortcutContext(_ normalizedTranscript: String) -> Bool {
        // Structural only: questions, planning verbs, and "take a look" review
        // language must not become Finder opens. Avoid product-specific phrase
        // denylists that only cover today's transcripts.
        let planningOrQuestionPattern = #"^(?:(?:can|could|would|will)\s+you\s+|please\s+)?(?:look\s+into|take\s+a\s+look(?:\s+at)?|research|investigate|propose|design|plan|think\s+about|tell\s+me|explain|is|are|was|were|do|does|did|what|where|why|how)\b"#
        return normalizedTranscript.range(of: planningOrQuestionPattern, options: .regularExpression) != nil
    }

    static func relativeFolderOpenRequest(
        from transcript: String,
        baseURL: URL,
        fileManager: FileManager = .default
    ) -> OpenClickyFolderOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let normalizedTranscript = normalizedFolderCommandText(trimmedTranscript)
        guard containsFolderOpenVerb(normalizedTranscript),
              !isBlockedFolderOpenShortcutContext(normalizedTranscript) else { return nil }

        let targetName = relativeFolderTargetName(from: normalizedTranscript)
        guard !targetName.isEmpty else { return nil }

        let directCandidate = baseURL.appendingPathComponent(targetName, isDirectory: true)
        if existingDirectoryURL(directCandidate, fileManager: fileManager) != nil {
            return OpenClickyFolderOpenRequest(
                url: directCandidate,
                displayName: "\(targetName) folder",
                instruction: trimmedTranscript
            )
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let normalizedTargetName = normalizedFolderName(targetName)
        for child in children {
            guard existingDirectoryURL(child, fileManager: fileManager) != nil else { continue }
            let childName = child.lastPathComponent
            if normalizedFolderName(childName) == normalizedTargetName {
                return OpenClickyFolderOpenRequest(
                    url: child,
                    displayName: "\(childName) folder",
                    instruction: trimmedTranscript
                )
            }
        }

        return nil
    }

    static func relativeFolderTargetName(from normalizedTranscript: String) -> String {
        if let namedFolder = namedFolderTarget(from: normalizedTranscript) {
            return namedFolder
        }

        var target = normalizedTranscript
        let prefixes = [
            "can you",
            "could you",
            "would you",
            "will you",
            "please",
            "now"
        ]
        for prefix in prefixes where target.hasPrefix(prefix + " ") {
            target.removeFirst(prefix.count)
            target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commandPrefixes = [
            "go into the",
            "go into",
            "go in the",
            "go in",
            "go to the",
            "go to",
            "navigate to the",
            "navigate to",
            "open the",
            "open",
            "show the",
            "show",
            "reveal the",
            "reveal",
            "inside the",
            "inside"
        ]

        for prefix in commandPrefixes where target.hasPrefix(prefix + " ") {
            target.removeFirst(prefix.count)
            target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        let suffixes = [
            "folder",
            "directory",
            "in there",
            "there",
            "please"
        ]
        var didStripSuffix = true
        while didStripSuffix {
            didStripSuffix = false
            for suffix in suffixes where target == suffix || target.hasSuffix(" " + suffix) {
                target.removeLast(suffix.count)
                target = target.trimmingCharacters(in: .whitespacesAndNewlines)
                didStripSuffix = true
            }
        }

        return target
    }

    static func namedFolderTarget(from normalizedTranscript: String) -> String? {
        let patterns = [
            #"(?i)(?:go into|go in|go to|navigate to|open|show|reveal)\s+(?:the\s+)?(.+?)\s+(?:folder|directory)(?:\s+(?:open|open up|please|there|in there))*$"#,
            #"(?i)(?:in|inside)\s+(?:that|this|the)\s+folder\s+(?:there(?:'s| is)?\s+)?(?:a\s+|an\s+|the\s+)?(.+?)\s+(?:folder|directory)(?:\s+(?:open|open up|please|there|in there))*$"#,
            #"(?i)(?:there(?:'s| is)?\s+)?(?:a\s+|an\s+|the\s+)?(.+?)\s+(?:folder|directory)\s+(?:open|open up)(?:\s+please)?$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalizedTranscript.startIndex..<normalizedTranscript.endIndex, in: normalizedTranscript)
            guard let match = regex.firstMatch(in: normalizedTranscript, range: range),
                  let targetRange = Range(match.range(at: 1), in: normalizedTranscript) else {
                continue
            }

            let target = String(normalizedTranscript[targetRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                return folderSpeechAlias(for: target)
            }
        }

        return nil
    }

    static func normalizedFolderCommandText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s_-]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedFolderName(_ value: String) -> String {
        folderSpeechAlias(for: normalizedFolderCommandText(value))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func folderSpeechAlias(for value: String) -> String {
        let normalized = normalizedFolderCommandText(value)
        switch normalized {
        case "script", "scripps":
            return "scripts"
        default:
            return normalized
        }
    }

    static func existingDirectoryURL(_ url: URL, fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    static func existingOpenClickySourceDirectoryURL(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Users/jkneen/Documents/GitHub/openclicky",
            "\(home)/Documents/GitHub/openclicky"
        ]

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
        }

        return nil
    }

    static func cleanedApplicationOpenTarget(_ rawTarget: String) -> String {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingActionPatterns = [
            #"(?i)\s+(?:and|then)\s+(?:(?:can|could|would|will)\s+you\s+)?(?:play|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose|go\s+to|navigate\s+to|browse\s+to|visit)\b.*$"#,
            #"(?i)\s+to\s+(?:(?:can|could|would|will)\s+you\s+)?(?:play|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose)\b.*$"#
        ]
        for pattern in trailingActionPatterns {
            target = target.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return target.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—…"))
    }

    static func normalizedApplicationName(from rawTarget: String) -> String {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?-–— "))
        target = target.replacingOccurrences(
            of: #"(?i)^(?:my|the|a|an)\s+"#,
            with: "",
            options: .regularExpression
        )
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)

        let removableSuffixes = [" app", " application"]
        for suffix in removableSuffixes where target.localizedCaseInsensitiveContains(suffix) {
            if target.lowercased().hasSuffix(suffix) {
                target.removeLast(suffix.count)
                target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lowered = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        switch lowered {
        case "chrome", "google chrome":
            return "Google Chrome"
        case "safari":
            return "Safari"
        case "xcode":
            return "Xcode"
        case "terminal":
            return "Terminal"
        case "ghostty", "ghost tty", "ghostie", "ghosty":
            return "Ghostty"
        case "finder":
            return "Finder"
        case "settings", "system settings":
            return "System Settings"
        case "mail":
            return "Mail"
        case "messages":
            return "Messages"
        case "notes":
            return "Notes"
        case "reminders":
            return "Reminders"
        case "calendar":
            return "Calendar"
        case "slack":
            return "Slack"
        case "spotify":
            return "Spotify"
        case "cursor":
            return "Cursor"
        case "codex":
            return "Codex"
        case "github desktop",
             "git hub desktop",
             "gate hub desktop",
             "get hub desktop",
             "github",
             "git hub",
             "gate hub",
             "get hub":
            return "GitHub Desktop"
        default:
            return target
        }
    }

    static func cleanedReminderTitle(_ rawTitle: String) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        title = stripMatchingQuotes(from: title)
        title = title.replacingOccurrences(
            of: #"(?i)^(?:a\s+|an\s+|the\s+)?(?:reminder|task|todo|to-do)\s+(?:to|for)\s+"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)[,\s]+(?:please|thanks|thank\s+you)$"#,
            with: "",
            options: .regularExpression
        )
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    static func isReminderTitlePlaceholder(_ value: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(value)
        return [
            "",
            "it",
            "this",
            "that",
            "something",
            "a reminder",
            "a task",
            "test"
        ].contains(normalized)
    }

    static func cleanedMessagesSearchName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        name = stripMatchingQuotes(from: name)
        name = name.replacingOccurrences(
            of: #"(?i)[,\s]+(?:please|okay|ok|thanks|thank\s+you)$"#,
            with: "",
            options: .regularExpression
        )
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    static func isMessagesSearchPlaceholder(_ value: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(value)
        return ["", "someone", "somebody", "anyone", "people", "them", "him", "her"].contains(normalized)
    }

    static func nativeAutomationErrorMessage(
        appName: String,
        result: OpenClickyLocalAutomationResult
    ) -> String {
        let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
        let normalizedDetail = detail
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        if normalizedDetail.contains("not authorized")
            || normalizedDetail.contains("not permitted")
            || normalizedDetail.contains("not allowed")
            || normalizedDetail.contains("errAEEventNotPermitted".lowercased()) {
            return "macOS blocked \(appName) automation. enable OpenClicky for \(appName) in System Settings."
        }

        let shortDetail = detail
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
        return "\(appName) automation hit a blocker: \(shortDetail)"
    }

    static func isLocalAppOpenPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenNormalized = SpokenText.normalizedSpokenCommandText(value)
        return ["", "my", "the", "a", "an", "it", "that", "this"].contains(normalized)
            || ["", "my", "the", "a", "an", "it", "that", "this"].contains(spokenNormalized)
    }

    static func isReservedAgentOpenTarget(_ value: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(value)
        let stripped = normalized.replacingOccurrences(
            of: #"^(?:my|the|a|an)\s+"#,
            with: "",
            options: .regularExpression
        )

        if ["", "agent", "agents", "agent task", "agent job", "agent session"].contains(stripped) {
            return true
        }
        return stripped.hasPrefix("agent ")
            || stripped.hasPrefix("agents ")
            || stripped.hasSuffix(" agent")
            || stripped.hasSuffix(" agents")
            || stripped.hasSuffix(" agent task")
            || stripped.hasSuffix(" agent job")
            || stripped.hasSuffix(" agent session")
            || stripped.hasPrefix("codex task ")
            || stripped.hasPrefix("codex job ")
            || stripped.hasPrefix("codex session ")
    }

    static func isLikelyFileOrFolderOpenTarget(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains(".") {
            return true
        }

        let normalized = normalizedFolderCommandText(value)
        if normalized.contains(" folder") || normalized.contains(" directory") {
            return true
        }
        if normalized.contains(" file") || normalized.contains(" in ") || normalized.contains(" inside ") {
            return true
        }
        return false
    }

    static func isLikelyWebOpenTarget(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—"))
        guard !raw.isEmpty else { return false }

        let lowered = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.") {
            return true
        }
        if lowered.range(of: #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\b"#, options: .regularExpression) != nil {
            return true
        }

        let normalized = SpokenText.normalizedSpokenCommandText(raw)
        let navigationSignals = [
            " go to ",
            " browse to ",
            " navigate to ",
            " visit ",
            " website",
            " webpage",
            " web page",
            " url"
        ]
        return navigationSignals.contains { " \(normalized) ".contains($0) }
    }

    static func nativeTypeRequest(from transcript: String) -> OpenClickyNativeTypeRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field)\s+(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(.+?)\s+(?:into|in)\s+(?:the\s+)?(?:[a-z0-9\s-]+?\s+)?(?:input|pin|code|box|search|field|text\s+field|browser|page|window|app)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(.+?)(?:\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field))?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field)\s+(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(.+?)\s+(?:into|in)\s+(?:the\s+)?(?:[a-z0-9\s-]+?\s+)?(?:input|pin|code|box|search|field|text\s+field|browser|page|window|app)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(.+?)(?:\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field))?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let textRange = Range(match.range(at: 1), in: candidate) else { continue }

            var text = String(candidate[textRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!? "))

            text = stripMatchingQuotes(from: text)
            guard !text.isEmpty, !isTypePlaceholder(text) else { return nil }

            return OpenClickyNativeTypeRequest(
                text: text,
                targetDescription: candidate
            )
        }

        return nil
    }

    static func nativeClickRequest(from transcript: String) -> OpenClickyNativeClickRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        let referentialTargets: Set<String> = [
            "it",
            "that",
            "this",
            "that one",
            "this one",
            "the thing",
            "the button",
            "the link",
            "the tile"
        ]

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:click|tap|select|choose)\s+(?:on\s+)?(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|play)\s+(?:the\s+)?(.+?)\s+(?:tile|button|link|item|profile|show|movie|episode)[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let targetRange = Range(match.range(at: 1), in: candidate) else { continue }
            let target = String(candidate[targetRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
            let targetNormalized = SpokenText.normalizedSpokenCommandText(target)
            let isTapKeyCommand = normalized.hasPrefix("tap ")
                && [
                    "escape", "esc", "enter", "return", "tab", "space", "spacebar",
                    "delete", "backspace", "left", "right", "up", "down",
                    "left arrow", "right arrow", "up arrow", "down arrow"
                ].contains(targetNormalized)
            if isTapKeyCommand { return nil }
            guard !target.isEmpty,
                  !["something", "somewhere", "anything"].contains(targetNormalized) else { return nil }

            return OpenClickyNativeClickRequest(
                targetDescription: candidate,
                targetPhrase: referentialTargets.contains(targetNormalized) ? nil : target,
                prefersLastPointedElement: referentialTargets.contains(targetNormalized)
            )
        }

        if [
            "can you click it",
            "could you click it",
            "click it",
            "tap it",
            "select it",
            "choose it",
            "click that",
            "tap that",
            "select that",
            "choose that"
        ].contains(normalized) {
            return OpenClickyNativeClickRequest(
                targetDescription: candidate,
                targetPhrase: nil,
                prefersLastPointedElement: true
            )
        }

        return nil
    }

    static func stripMatchingQuotes(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last else {
            return trimmed
        }

        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’")
        ]

        for pair in quotePairs where first == pair.0 && last == pair.1 {
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    static func isTypePlaceholder(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            "something",
            "text",
            "this",
            "that",
            "into the window",
            "in the window",
            "into the field",
            "in the field"
        ].contains(normalized)
    }

    static func nativeKeyPressRequest(from transcript: String) -> OpenClickyNativeKeyPressRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        // Voice follow-ups often omit the imperative after OpenClicky has
        // already established the focused document, for example "to the next
        // page." Treat these as direct navigation actions inside the current
        // voice turn instead of letting them fall through to visual chat.
        let pageNavigationPatterns: [(pattern: String, key: String)] = [
            (#"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:go|move|take\s+me|skip)(?:\s+to)?\s+)?(?:to\s+)?(?:the\s+)?next\s+page[\.\!\?]*\s*$"#, "pagedown"),
            (#"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:go|move|take\s+me)(?:\s+to)?\s+)?(?:to\s+)?(?:the\s+)?(?:previous|prior)\s+page[\.\!\?]*\s*$"#, "pageup"),
            (#"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:scroll|move)\s+(?:a\s+|one\s+)?page\s+(down|up)[\.\!\?]*\s*$"#, "")
        ]
        for navigation in pageNavigationPatterns {
            guard let regex = try? NSRegularExpression(pattern: navigation.pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range) else { continue }
            let key: String
            if navigation.key.isEmpty,
               match.numberOfRanges > 1,
               let directionRange = Range(match.range(at: 1), in: candidate) {
                key = candidate[directionRange].lowercased() == "down" ? "pagedown" : "pageup"
            } else {
                key = navigation.key
            }
            return OpenClickyNativeKeyPressRequest(
                key: key,
                modifiers: [],
                targetDescription: candidate
            )
        }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:press|hit|tap)\s+(.+?)(?:\s+(?:in|into)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field))?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:send)\s+(?:the\s+)?(.+?)\s+key(?:\s+(?:to|into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field))?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let keyRange = Range(match.range(at: 1), in: candidate) else { continue }

            let rawKeySpec = cleanedNativeKeySpecTargetContext(String(candidate[keyRange]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
            guard let parsed = parsedNativeKeySpec(from: rawKeySpec) else { return nil }

            return OpenClickyNativeKeyPressRequest(
                key: parsed.key,
                modifiers: parsed.modifiers,
                targetDescription: candidate
            )
        }

        return nil
    }

    static func cleanedNativeKeySpecTargetContext(_ rawKeySpec: String) -> String {
        rawKeySpec
            .replacingOccurrences(
                of: #"(?i)\s+(?:in|inside|within|to)\s+(?:the\s+)?[a-z0-9][a-z0-9\s&'’.-]*(?:\s+(?:app|application|window))?\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parsedNativeKeySpec(from rawKeySpec: String) -> (key: String, modifiers: [String])? {
        let normalizedKeySpec = rawKeySpec
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: " plus ", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard !normalizedKeySpec.isEmpty else { return nil }

        var modifiers: [String] = []
        var keyTokens: [String] = []
        for token in normalizedKeySpec {
            switch token {
            case "cmd", "command":
                modifiers.append("command")
            case "ctrl", "control":
                modifiers.append("control")
            case "option", "alt":
                modifiers.append("option")
            case "shift":
                modifiers.append("shift")
            case "the", "key", "button":
                break
            default:
                keyTokens.append(token)
            }
        }

        let key = keyTokens.joined()
        guard !key.isEmpty, !["key", "button"].contains(key) else { return nil }
        let normalizedKey = normalizedNativeKeyName(key)
        guard isSupportedNativeKeyName(normalizedKey) else { return nil }
        return (key: normalizedKey, modifiers: modifiers)
    }

    static func normalizedNativeKeyName(_ key: String) -> String {
        switch key {
        case "play", "pause", "playpause", "playorpause":
            return "space"
        case "return":
            return "enter"
        case "spacebar":
            return "space"
        case "backspace":
            return "delete"
        case "leftarrow":
            return "left"
        case "rightarrow":
            return "right"
        case "uparrow":
            return "up"
        case "downarrow":
            return "down"
        default:
            return key
        }
    }

    static func isSupportedNativeKeyName(_ key: String) -> Bool {
        if key.count == 1,
           let scalar = key.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) {
            return true
        }

        let supportedNames: Set<String> = [
            "return", "enter",
            "tab",
            "space",
            "delete", "backspace",
            "forwarddelete", "del",
            "escape", "esc",
            "left", "leftarrow",
            "right", "rightarrow",
            "down", "downarrow",
            "up", "uparrow",
            "home", "end",
            "pageup", "pagedown",
            "f1", "f2", "f3", "f4",
            "f5", "f6", "f7", "f8",
            "f9", "f10", "f11", "f12"
        ]
        return supportedNames.contains(key)
    }

    static func applicationBundleIdentifiers(for appName: String) -> [String] {
        switch appName {
        case "Google Chrome":
            return ["com.google.Chrome"]
        case "Safari":
            return ["com.apple.Safari"]
        case "Xcode":
            return ["com.apple.dt.Xcode"]
        case "Terminal":
            return ["com.apple.Terminal"]
        case "Ghostty":
            return ["com.mitchellh.ghostty"]
        case "Finder":
            return ["com.apple.finder"]
        case "System Settings":
            return ["com.apple.SystemSettings", "com.apple.systempreferences"]
        case "Mail":
            return ["com.apple.mail"]
        case "Messages":
            return ["com.apple.MobileSMS"]
        case "Notes":
            return ["com.apple.Notes"]
        case "Reminders":
            return ["com.apple.reminders"]
        case "Calendar":
            return ["com.apple.iCal"]
        case "Slack":
            return ["com.tinyspeck.slackmacgap"]
        case "Spotify":
            return ["com.spotify.client"]
        case "GitHub Desktop":
            return ["com.github.GitHubClient"]
        default:
            return []
        }
    }

    static func canResolveApplicationWithoutShellOpen(named appName: String) -> Bool {
        resolvedApplicationURL(named: appName) != nil
    }

    static func activateRunningApplication(named appName: String) {
        for bundleIdentifier in applicationBundleIdentifiers(for: appName) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    static func applicationOwner(_ owner: String, matches appName: String) -> Bool {
        let normalizedOwner = normalizedApplicationName(from: owner)
        if normalizedOwner == appName { return true }
        let foldedOwner = owner.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        let foldedApp = appName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        return foldedOwner == foldedApp
    }

    static func standardApplicationURL(named appName: String) -> URL? {
        let applicationDirectories = [
            "/Applications",
            "/System/Applications",
            "\(NSHomeDirectory())/Applications"
        ]

        return applicationDirectories
            .map { URL(fileURLWithPath: $0).appendingPathComponent("\(appName).app", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
