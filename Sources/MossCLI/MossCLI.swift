import Foundation

@main
struct MossCLI {
    static func main() {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        switch args[1] {
        case "agent":
            handleAgent(Array(args.dropFirst(2)))
        case "hook":
            handleHook(Array(args.dropFirst(2)))
        case "help", "--help", "-h":
            printUsage()
        default:
            fputs("Unknown command: \(args[1])\n", stderr)
            printUsage()
            exit(1)
        }
    }

    // MARK: - Agent commands

    static func handleAgent(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss agent <status|session|task> ...\n", stderr)
            exit(1)
        }

        switch args[0] {
        case "status":
            handleAgentStatus(Array(args.dropFirst()))
        case "session":
            handleAgentSession(Array(args.dropFirst()))
        case "task":
            handleAgentTask(Array(args.dropFirst()))
        default:
            fputs("Unknown agent subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

    static func handleAgentStatus(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss agent status <set|auto|get> [value]\n", stderr)
            exit(1)
        }

        let validStatuses = ["running", "waiting", "idle", "error", "none"]

        switch args[0] {
        case "set":
            guard args.count >= 2 else {
                fputs("Usage: moss agent status set <\(validStatuses.joined(separator: "|"))>\n", stderr)
                exit(1)
            }
            guard validStatuses.contains(args[1]) else {
                fputs("Invalid status: \(args[1]). Must be one of: \(validStatuses.joined(separator: ", "))\n", stderr)
                exit(1)
            }
            sendCommand(command: "set_status", value: args[1])

        case "auto":
            guard args.count >= 2 else {
                fputs("Usage: moss agent status auto <\(validStatuses.joined(separator: "|"))>\n", stderr)
                exit(1)
            }
            guard validStatuses.contains(args[1]) else {
                fputs("Invalid status: \(args[1]). Must be one of: \(validStatuses.joined(separator: ", "))\n", stderr)
                exit(1)
            }
            sendCommand(command: "set_auto_status", value: args[1])

        case "get":
            sendCommand(command: "get_status", value: nil)

        default:
            fputs("Unknown status subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

    static func handleAgentSession(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss agent session <start> <session_id>\n", stderr)
            exit(1)
        }

        switch args[0] {
        case "start":
            guard args.count >= 2 else {
                fputs("Usage: moss agent session start <session_id>\n", stderr)
                exit(1)
            }
            sendCommand(command: "agent_session_start", value: args[1])

        default:
            fputs("Unknown session subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

    static func handleAgentTask(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss agent task <created|completed|reset> ...\n", stderr)
            exit(1)
        }

        switch args[0] {
        case "created":
            guard args.count >= 3 else {
                fputs("Usage: moss agent task created <task_id> <task_subject>\n", stderr)
                exit(1)
            }
            let taskId = args[1]
            let subject = args.dropFirst(2).joined(separator: " ")
            let payload = "{\"id\":\(jsonEscape(taskId)),\"subject\":\(jsonEscape(subject))}"
            sendCommand(command: "task_created", value: payload)

        case "completed":
            guard args.count >= 2 else {
                fputs("Usage: moss agent task completed <task_id>\n", stderr)
                exit(1)
            }
            let payload = "{\"id\":\(jsonEscape(args[1]))}"
            sendCommand(command: "task_completed", value: payload)

        case "reset":
            sendCommand(command: "task_reset", value: nil)

        default:
            fputs("Unknown task subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

    // MARK: - Hook commands

    static func handleHook(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss hook <claude> <install|uninstall|handle>\n", stderr)
            exit(1)
        }

        switch args[0] {
        case "claude":
            guard args.count >= 2 else {
                fputs("Usage: moss hook claude <install|uninstall|handle>\n", stderr)
                exit(1)
            }
            switch args[1] {
            case "install":
                ClaudeHookInstaller.install()
            case "uninstall":
                ClaudeHookInstaller.uninstall()
            case "handle":
                handleClaudeHook()
            default:
                fputs("Unknown hook claude subcommand: \(args[1])\n", stderr)
                exit(1)
            }

        default:
            fputs("Unknown hook target: \(args[0]). Available: claude\n", stderr)
            exit(1)
        }
    }

    // MARK: - Claude Code hook handler (reads stdin JSON, maps to generic IPC)

    static func handleClaudeHook() {
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
            exit(0)
        }

        let event = json["hook_event_name"] as? String ?? ""
        let sessionId = json["session_id"] as? String ?? ""

        switch event {
        case "SessionStart":
            guard !sessionId.isEmpty else { exit(0) }
            trySendCommand(command: "agent_session_start", value: sessionId)
            trySendCommand(command: "set_auto_status", value: "running")

        case "UserPromptSubmit":
            trySendCommand(command: "set_auto_status", value: "running")

        case "Notification":
            let notificationType = json["notification_type"] as? String ?? ""
            switch notificationType {
            case "permission_prompt", "idle_prompt", "elicitation_dialog":
                trySendCommand(command: "set_auto_status", value: "waiting")
            default:
                break
            }

        case "Stop":
            trySendCommand(command: "set_auto_status", value: "idle")

        case "StopFailure":
            trySendCommand(command: "set_auto_status", value: "error")

        case "TaskCreated":
            let taskId = json["task_id"] as? String ?? ""
            let taskSubject = json["task_subject"] as? String ?? ""
            guard !taskId.isEmpty else { exit(0) }
            let payload = "{\"id\":\(jsonEscape(taskId)),\"subject\":\(jsonEscape(taskSubject)),\"session_id\":\(jsonEscape(sessionId))}"
            trySendCommand(command: "task_created", value: payload)

        case "TaskCompleted":
            let taskId = json["task_id"] as? String ?? ""
            guard !taskId.isEmpty else { exit(0) }
            let payload = "{\"id\":\(jsonEscape(taskId)),\"session_id\":\(jsonEscape(sessionId))}"
            trySendCommand(command: "task_completed", value: payload)

        default:
            break
        }
        exit(0)
    }

    // MARK: - IPC

    static func sendCommand(command: String, value: String?) {
        guard let socketPath = ProcessInfo.processInfo.environment["MOSS_SOCKET_PATH"] else {
            fputs("Error: MOSS_SOCKET_PATH not set. Are you running inside a Moss terminal?\n", stderr)
            exit(1)
        }
        guard let surfaceId = ProcessInfo.processInfo.environment["MOSS_SURFACE_ID"] else {
            fputs("Error: MOSS_SURFACE_ID not set. Are you running inside a Moss terminal?\n", stderr)
            exit(1)
        }

        let client = SocketClient(path: socketPath)
        do {
            try client.connect()
            let response = try client.send(
                surfaceId: surfaceId,
                command: command,
                value: value
            )
            print(response.message)
            exit(response.success ? 0 : 1)
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Send IPC command, silently ignoring errors (for hook mode).
    static func trySendCommand(command: String, value: String?) {
        guard let socketPath = ProcessInfo.processInfo.environment["MOSS_SOCKET_PATH"],
              let surfaceId = ProcessInfo.processInfo.environment["MOSS_SURFACE_ID"]
        else { return }

        let client = SocketClient(path: socketPath)
        guard (try? client.connect()) != nil else { return }
        _ = try? client.send(surfaceId: surfaceId, command: command, value: value)
    }

    // MARK: - Helpers

    private static func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func printUsage() {
        print("""
        Usage: moss <command> [arguments]

        Commands:
          agent status set <running|waiting|idle|error|none>    Set terminal agent status
          agent status auto <running|waiting|idle|error|none>   Set automatic agent status
          agent status get                                      Get terminal agent status
          agent session start <session_id>                      Start agent session
          agent task created <id> <subject>                     Track a new task
          agent task completed <id>                             Mark a task as done
          agent task reset                                      Clear all tracked tasks
          hook claude install                                   Install Claude Code hooks
          hook claude uninstall                                 Remove Claude Code hooks
          help                                                  Show this help
        """)
    }
}
