// MCPSetup.swift
// VocaMac
//
// How a coding agent is pointed at VocaMac's MCP server: the command to
// register it with Claude Code and the guide for other clients.

import Foundation

enum MCPSetup {
    /// The setup guide in the repository docs.
    static let guideURL = URL(string: "https://github.com/VocaHQ/vocamac/blob/main/docs/CLI.md#mcp-server")
        ?? URL(fileURLWithPath: "/")

    /// The binary an agent should start: this app's own executable.
    static func executablePath(bundle: Bundle = .main) -> String {
        bundle.executableURL?.path ?? "/Applications/VocaMac.app/Contents/MacOS/VocaMac"
    }

    /// `claude mcp add` for this copy of VocaMac, quoted for a shell.
    static func claudeCodeCommand(executablePath: String = executablePath()) -> String {
        "claude mcp add vocamac -- \(shellQuoted(executablePath)) --mcp"
    }

    /// `path` as one shell word.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
