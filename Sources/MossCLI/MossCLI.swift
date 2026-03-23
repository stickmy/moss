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

    static func printUsage() {
        print("""
        Usage: moss <command> [arguments]

        Commands:
          status set <pending|none>           Set terminal status
          status auto <pending|none>          Set automatic terminal status
          status get                          Get terminal status
          help                                Show this help
        """)
    }
}
