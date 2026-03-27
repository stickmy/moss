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
        case "status":
            handleStatus(Array(args.dropFirst(2)))
        case "task":
            handleTask(Array(args.dropFirst(2)))
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

    static func handleStatus(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss status <set|get> [value]\n", stderr)
            exit(1)
        }

        switch args[0] {
        case "set":
            guard args.count >= 2 else {
                fputs("Usage: moss status set <pending|none>\n", stderr)
                exit(1)
            }
            let value = args[1]
            guard ["pending", "none"].contains(value) else {
                fputs("Invalid status: \(value). Must be pending or none.\n", stderr)
                exit(1)
            }
            sendCommand(command: "set_status", value: value)

        case "auto":
            guard args.count >= 2 else {
                fputs("Usage: moss status auto <pending|none>\n", stderr)
                exit(1)
            }
            guard let value = normalizedAutomaticStatusValue(args[1]) else {
                fputs("Invalid status: \(args[1]). Must be pending or none.\n", stderr)
                exit(1)
            }
            sendCommand(command: "set_auto_status", value: value)

        case "get":
            sendCommand(command: "get_status", value: nil)

        default:
            fputs("Unknown status subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

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

    static func normalizedAutomaticStatusValue(_ value: String) -> String? {
        switch value {
        case "running":
            return "none"
        case "pending", "none":
            return value
        default:
            return nil
        }
    }

    static func handleTask(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss task <created|completed|reset> [arguments]\n", stderr)
            exit(1)
        }

        switch args[0] {
        case "created":
            guard args.count >= 3 else {
                fputs("Usage: moss task created <task_id> <task_subject>\n", stderr)
                exit(1)
            }
            let taskId = args[1]
            let subject = args.dropFirst(2).joined(separator: " ")
            let payload = "{\"id\":\(jsonEscape(taskId)),\"subject\":\(jsonEscape(subject))}"
            sendCommand(command: "task_created", value: payload)

        case "completed":
            guard args.count >= 2 else {
                fputs("Usage: moss task completed <task_id>\n", stderr)
                exit(1)
            }
            sendCommand(command: "task_completed", value: args[1])

        case "reset":
            sendCommand(command: "task_reset", value: nil)

        case "hook":
            handleTaskHook()

        default:
            fputs("Unknown task subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

    private static func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Hook management

    static func handleHook(_ args: [String]) {
        guard args.count >= 1 else {
            fputs("Usage: moss hook <install|uninstall>\n", stderr)
            exit(1)
        }
        switch args[0] {
        case "install":
            HookInstaller.install()
        case "uninstall":
            HookInstaller.uninstall()
        default:
            fputs("Unknown hook subcommand: \(args[0])\n", stderr)
            exit(1)
        }
    }

    // MARK: - Hook stdin handler (called by Claude Code hook)

    static func handleTaskHook() {
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
            exit(0)
        }

        let event = json["hook_event_name"] as? String ?? ""
        let taskId = json["task_id"] as? String ?? ""
        let taskSubject = json["task_subject"] as? String ?? ""
        guard !taskId.isEmpty else { exit(0) }

        switch event {
        case "TaskCreated":
            let payload = "{\"id\":\(jsonEscape(taskId)),\"subject\":\(jsonEscape(taskSubject))}"
            trySendCommand(command: "task_created", value: payload)
        case "TaskCompleted":
            trySendCommand(command: "task_completed", value: taskId)
        default:
            break
        }
        exit(0)
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

    static func printUsage() {
        print("""
        Usage: moss <command> [arguments]

        Commands:
          status set <pending|none>           Set terminal status
          status auto <pending|none>          Set automatic terminal status
          status get                          Get terminal status
          task created <id> <subject>         Track a new task
          task completed <id>                 Mark a task as done
          task reset                          Clear all tracked tasks
          hook install                        Install Claude Code hooks globally
          hook uninstall                      Remove Claude Code hooks
          help                                Show this help
        """)
    }
}
