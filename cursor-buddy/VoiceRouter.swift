import Foundation

/// Pure, side-effect-free classification vocabulary for the voice routing
/// cascade. Everything here operates purely on its `String` arguments.
nonisolated enum VoiceRouter {

    // MARK: Agent-work vocabulary

    static func containsAgentWorkAction(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:check|look\s+at|take\s+a\s+look|inspect|review|audit|fix|modify|change|update|edit|build|create|make|write|draft|research|search|find|summari[sz]e|organize|clean\s+up|cleanup|test|run|install|compare|read|move|rename|delete|prune|optimi[sz]e|wire|implement|add|remove|route|delegate|ensure|verify|validate|confirm|diagnose|investigate|repair|polish|improve|finish|sort\s+out|deal\s+with|take\s+care\s+of|make\s+sure|look\s+into|figure\s+out)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
    }

    static func containsDurableWorkTarget(_ normalized: String) -> Bool {
        let targetPattern = #"\b(?:openclicky|clicky|github|repo|repository|codebase|project|app|settings|preference|preferences|log|logs|memory|skill|skills|desktop|download|downloads|document|documents|folder|folders|file|files|code|diff|git|branch|pull\s+request|pr|issue|issues|bug|test|tests|build|swift|xcode|email|gmail|calendar|spreadsheet|sheet|doc|slides|voice|realtime|computer\s+use|tool|tools|tooling|model|models|routing|route|background|agent\s+mode)\b"#
        return normalized.range(of: targetPattern, options: .regularExpression) != nil
    }

    static func containsFreshResearchRequest(_ normalized: String) -> Bool {
        let researchPattern = #"\b(?:latest|live|price|news|weather|schedule|standings|research|look\s+up|search\s+(?:the\s+)?web|google|browse)\b"#
        return normalized.range(of: researchPattern, options: .regularExpression) != nil
    }

    static func isSensitiveOrDestructiveAgentTaskRequest(_ normalized: String) -> Bool {
        let destructivePattern = #"\b(?:delete|remove|erase|wipe|destroy|drop|revoke|reset|nuke|clear|purge|uninstall|terminate|kill)\b"#
        let broadScopePattern = #"\b(?:all|everything|entire|whole)\b"#
        let destructiveTargetPattern = #"\b(?:file|files|folder|folders|directory|directories|repo|repository|branch|branches|commit|commits|tag|tags|history|database|databases|keychain|account|accounts)\b"#
        let sensitiveTargetsPattern = #"\b(?:account|accounts|credential|credentials|password|passwords|token|tokens|api\s*key|secret|secrets|permission|permissions|auth|ssh|private\s+key|keychain|database|databases|prod|production|system\s+settings)\b"#

        let hasDestructiveVerb = normalized.range(of: destructivePattern, options: .regularExpression) != nil
        let hasBroadScope = normalized.range(of: broadScopePattern, options: .regularExpression) != nil
        let hasDestructiveTarget = normalized.range(of: destructiveTargetPattern, options: .regularExpression) != nil
        let hasSensitiveTarget = normalized.range(of: sensitiveTargetsPattern, options: .regularExpression) != nil

        // Safety policy:
        // - credential/permission/auth targets are always confirmation-worthy.
        // - destructive verbs are confirmation-worthy when aimed at a destructive target
        //   or broad-scope operation.
        return hasSensitiveTarget || (hasDestructiveVerb && (hasBroadScope || hasDestructiveTarget))
    }

    // MARK: Hybrid (do-now + fix-in-background) cues

    static func containsHybridForegroundCue(_ normalized: String) -> Bool {
        let foregroundPattern = #"\b(?:what|why|how|who|when|where|explain|tell\s+me|describe|summari[sz]e|answer|quick\s+(?:answer|thought|view)|what\s+do\s+you\s+think|do\s+you\s+think)\b"#
        return normalized.range(of: foregroundPattern, options: .regularExpression) != nil
    }

    static func containsHybridBackgroundCue(_ normalized: String) -> Bool {
        let backgroundPattern = #"\b(?:background|agent|agents|agent\s+mode|codex|do\s+the\s+work|work\s+on\s+it|take\s+care\s+of\s+it|also\s+(?:fix|implement|patch|research|find|check|review|update|change|build|create)|while\s+you(?:'re|re)?\s+(?:at\s+it|doing\s+that)|combination\s+of\s+the\s+two)\b"#
        return normalized.range(of: backgroundPattern, options: .regularExpression) != nil
    }

    // MARK: Natural / referential background-work cues

    static func containsNaturalBackgroundWorkCue(_ normalized: String) -> Bool {
        let cuePattern = #"\b(?:make\s+sure|ensure|verify|validate|confirm|look\s+into|figure\s+out|sort\s+out|deal\s+with|take\s+care\s+of|get\s+(?:this|that|it|.+?)\s+working|wire\s+(?:up|in)|hook\s+(?:up|in)|set\s+up|finish|polish|improve|repair|diagnose|investigate)\b"#
        if normalized.range(of: cuePattern, options: .regularExpression) != nil {
            return true
        }

        let makeUsePattern = #"\b(?:make|have)\b.{1,80}\b(?:use|using|route|routing|send|sending|call|calling)\b"#
        return normalized.range(of: makeUsePattern, options: .regularExpression) != nil
    }

    static func containsReferentialWorkTarget(_ normalized: String) -> Bool {
        let referencePattern = #"\b(?:this|that|it|here|current\s+(?:file|screen|window|page|repo|repository|project|app)|visible\s+(?:file|code|screen|window|page)|selected\s+(?:text|file|code|region)|the\s+(?:current|visible|selected)\s+(?:thing|part|file|code|screen|window|page)|what\s+we\s+(?:just\s+)?(?:talked|discussed)\s+about|the\s+thing\s+from\s+before)\b"#
        return normalized.range(of: referencePattern, options: .regularExpression) != nil
    }
}
