import Foundation

/// Substring used to identify Moss-installed hooks in Claude Code settings.
private let mossHookMarker = "hook claude handle"

enum ClaudeHookInstaller {
    private static let claudeSettingsPath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".claude/settings.json")
    }()

    private static let hookEvents = [
        "SessionStart",
        "TaskCreated",
        "TaskCompleted",
        "Notification",
        "Stop",
        "StopFailure",
        "UserPromptSubmit",
    ]

    static func install() {
        let mossPath = resolveExecutablePath()
        let hookCommand = "\"\(mossPath)\" hook claude handle"

        // Idempotent: remove existing moss hooks first
        let settings = readSettings()
        if hasMossHooks(in: settings) {
            removeMossHooks()
        }

        // Re-read after potential removal, then add fresh entries
        var fresh = readSettings()
        var hooks = fresh["hooks"] as? [String: Any] ?? [:]

        for event in hookEvents {
            var groups = hooks[event] as? [Any] ?? []
            let entry: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand,
                        "async": true,
                    ] as [String: Any]
                ] as [Any],
            ]
            groups.append(entry)
            hooks[event] = groups
            print("\(event): installed")
        }

        fresh["hooks"] = hooks
        writeSettings(fresh)
        print("Hook command: \(hookCommand)")
        print("Saved to \(claudeSettingsPath)")
    }

    static func uninstall() {
        let settings = readSettings()
        guard hasMossHooks(in: settings) else {
            print("No Moss hooks found")
            return
        }
        removeMossHooks()
        print("Saved to \(claudeSettingsPath)")
    }

    // MARK: - Detection

    private static func hasMossHooks(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in hookEvents {
            guard let groups = hooks[event] as? [Any] else { continue }
            for group in groups {
                guard let dict = group as? [String: Any],
                      let handlers = dict["hooks"] as? [Any]
                else { continue }
                for handler in handlers {
                    guard let h = handler as? [String: Any],
                          let cmd = h["command"] as? String
                    else { continue }
                    if cmd.contains(mossHookMarker) { return true }
                }
            }
        }
        return false
    }

    // MARK: - Removal

    private static func removeMossHooks() {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in hookEvents {
            guard let groups = hooks[event] as? [Any] else { continue }
            let before = groups.count

            let filtered = groups.filter { group -> Bool in
                guard let dict = group as? [String: Any],
                      let handlers = dict["hooks"] as? [Any]
                else { return true }
                let isMoss = handlers.contains { handler in
                    guard let h = handler as? [String: Any],
                          let cmd = h["command"] as? String
                    else { return false }
                    return cmd.contains(mossHookMarker)
                }
                return !isMoss
            }

            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
            let removed = before - filtered.count
            if removed > 0 { print("\(event): removed") }
        }

        settings["hooks"] = hooks
        writeSettings(settings)
    }

    // MARK: - Helpers

    private static func resolveExecutablePath() -> String {
        // Prefer the per-instance CLI path set by Moss.app
        if let cliPath = ProcessInfo.processInfo.environment["MOSS_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: cliPath)
        {
            return cliPath
        }

        // Fallback: stable symlink
        let installed = NSHomeDirectory() + "/.local/bin/moss"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }

        let arg0 = ProcessInfo.processInfo.arguments[0]
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).standardizedFileURL.path
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).standardizedFileURL.path
    }

    private static func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    private static func writeSettings(_ settings: [String: Any]) {
        let dir = (claudeSettingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            fputs("Error: failed to serialize settings\n", stderr)
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: claudeSettingsPath))
        } catch {
            fputs("Error writing \(claudeSettingsPath): \(error)\n", stderr)
            exit(1)
        }
    }
}
