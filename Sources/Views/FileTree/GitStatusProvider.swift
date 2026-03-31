import Foundation

/// Parses and provides git status for files in a directory.
enum GitStatusProvider {
    /// Runs `git status --porcelain -uall` and returns a map of absolute path → status.
    static func status(in directory: String) -> [String: GitFileStatus] {
        // Find git root first
        let rootPipe = Pipe()
        let rootProcess = Process()
        rootProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        rootProcess.arguments = ["rev-parse", "--show-toplevel"]
        rootProcess.currentDirectoryURL = URL(fileURLWithPath: directory)
        rootProcess.standardOutput = rootPipe
        rootProcess.standardError = Pipe()

        var gitRoot = directory
        do {
            try rootProcess.run()
            rootProcess.waitUntilExit()
            let rootData = rootPipe.fileHandleForReading.readDataToEndOfFile()
            if let root = String(data: rootData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty
            {
                gitRoot = root
            }
        } catch {
            return [:]
        }

        // Get porcelain status
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "-uall"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.index(line.startIndex, offsetBy: 0)]
            let workTreeStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let filePath = String(line.dropFirst(3))

            let absPath = (gitRoot as NSString).appendingPathComponent(filePath)

            let status: GitFileStatus
            if indexStatus == "?" && workTreeStatus == "?" {
                status = .untracked
            } else if indexStatus == "A" || workTreeStatus == "A" {
                status = .added
            } else if indexStatus == "D" || workTreeStatus == "D" {
                status = .deleted
            } else if indexStatus == "R" || workTreeStatus == "R" {
                status = .renamed
            } else if indexStatus == "U" || workTreeStatus == "U" {
                status = .conflict
            } else if indexStatus == "M" || workTreeStatus == "M" {
                status = .modified
            } else {
                continue
            }

            result[absPath] = status
        }

        return result
    }
}
