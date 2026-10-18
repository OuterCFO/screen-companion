import Foundation

/// Turns provider failures into one short sentence the user can act on.
nonisolated enum ProviderErrorMessage {
    static func userFacing(_ description: String, modelLabel: String) -> String? {
        let text = description.lowercased()
        if text.contains("not logged in") || text.contains("please run /login") {
            return "Claude Code isn't signed in. Open Terminal, run claude, and type /login."
        }
        if text.contains("out of usage credits") || text.contains("usage credits") {
            return "\(modelLabel) isn't available on your Claude plan right now. Choose another model, such as Sonnet 5.5."
        }
        if text.contains("hit your usage limit") || text.contains("usage limit") || text.contains("rate limit") {
            return "\(modelLabel) has reached its usage limit. Try again later or choose another model."
        }
        if text.contains("could not find its bundled codex executable") || text.contains("codex app-server is not running")
            || text.contains("codex app-server exited") {
            return "Codex isn't running. Reinstall the app's Codex runtime or choose a Claude model."
        }
        if text.contains("no provider is set up for") {
            return description
        }
        if text.contains("is not installed or its command could not be found") || text.contains("claude code is not installed") {
            return description
        }
        if text.contains("did not finish within") || text.contains("did not finish in time") {
            return "\(modelLabel) took too long to answer. Try again or choose a faster model."
        }
        return nil
    }
}
