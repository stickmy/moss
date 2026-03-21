import SwiftUI

struct FileDiffSummary: Equatable {
    let additions: Int
    let deletions: Int

    var totalChanges: Int { additions + deletions }
}

enum FileDiffError: LocalizedError {
    case notInGitRepository
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInGitRepository:
            return "Not in a git repository"
        case let .commandFailed(message):
            return message
        }
    }
}

enum FileDiffLoader {
    static func loadSummary(
        for url: URL,
        completion: @escaping (Result<FileDiffSummary, FileDiffError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadSummarySync(for: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func loadDiff(
        for url: URL,
        completion: @escaping (Result<String, FileDiffError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadDiffSync(for: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func loadSummarySync(for url: URL) -> Result<FileDiffSummary, FileDiffError> {
        switch runGit(arguments: ["diff", "--numstat", "HEAD", "--", url.lastPathComponent], in: url) {
        case let .success(output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let line = trimmed.split(separator: "\n").first else {
                return .success(FileDiffSummary(additions: 0, deletions: 0))
            }

            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            let additions = parts.indices.contains(0) ? Int(parts[0]) ?? 0 : 0
            let deletions = parts.indices.contains(1) ? Int(parts[1]) ?? 0 : 0
            return .success(FileDiffSummary(additions: additions, deletions: deletions))
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func loadDiffSync(for url: URL) -> Result<String, FileDiffError> {
        runGit(
            arguments: ["diff", "--no-ext-diff", "--no-color", "HEAD", "--", url.lastPathComponent],
            in: url
        )
    }

    private static func runGit(
        arguments: [String],
        in fileURL: URL
    ) -> Result<String, FileDiffError> {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = fileURL.deletingLastPathComponent()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            if errorOutput.localizedCaseInsensitiveContains("not a git repository") {
                return .failure(.notInGitRepository)
            }

            let message = errorOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.commandFailed(message.isEmpty ? "Unable to load diff" : message))
        }

        return .success(output)
    }
}

struct FileDiffView: View {
    let url: URL
    @Environment(\.mossTheme) private var theme
    @State private var diffContent: String = ""
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if isLoading {
                FileDiffPlaceholder(
                    icon: "arrow.trianglehead.branch",
                    title: "Loading diff",
                    message: "Gathering the latest changes for this file."
                )
            } else if let error {
                FileDiffPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: error,
                    message: "Try opening a tracked file inside a git repository."
                )
            } else if diffContent.isEmpty {
                FileDiffPlaceholder(
                    icon: "checkmark.seal",
                    title: "Working tree clean",
                    message: "There are no local changes for this file."
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diffContent.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(accentBarColor(for: line))
                                    .frame(width: 3)

                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(colorForDiffLine(line))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 4)
                                    .fixedSize(horizontal: true, vertical: false)

                                Spacer(minLength: 0)
                            }
                            .background(backgroundForDiffLine(line))
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill((theme?.border ?? Color(nsColor: .separatorColor)).opacity(0.12))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(10)
                }
                .background(diffSurfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(diffSurfaceBorder, lineWidth: 1)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(diffPanelBackground)
        .task(id: url) {
            loadDiff()
        }
    }

    private func colorForDiffLine(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.31, green: 0.72, blue: 0.46) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.87, green: 0.39, blue: 0.39) }
        if line.hasPrefix("@@") { return Color(red: 0.34, green: 0.67, blue: 0.92) }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return theme?.secondaryForeground ?? .secondary
        }
        return theme?.foreground ?? .primary
    }

    private func backgroundForDiffLine(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color(red: 0.31, green: 0.72, blue: 0.46).opacity(0.12)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color(red: 0.87, green: 0.39, blue: 0.39).opacity(0.12)
        }
        if line.hasPrefix("@@") {
            return Color(red: 0.34, green: 0.67, blue: 0.92).opacity(0.10)
        }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return (theme?.surfaceBackground ?? Color(nsColor: .controlBackgroundColor)).opacity(0.8)
        }
        return .clear
    }

    private func accentBarColor(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color(red: 0.31, green: 0.72, blue: 0.46)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color(red: 0.87, green: 0.39, blue: 0.39)
        }
        if line.hasPrefix("@@") {
            return Color(red: 0.34, green: 0.67, blue: 0.92)
        }
        return Color.clear
    }

    private var diffPanelBackground: Color {
        theme?.background ?? Color(nsColor: .controlBackgroundColor)
    }

    private var diffSurfaceBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.02)
            ?? Color(nsColor: .textBackgroundColor)
    }

    private var diffSurfaceBorder: Color {
        (theme?.border ?? Color(nsColor: .separatorColor)).opacity(0.55)
    }

    private func loadDiff() {
        isLoading = true
        error = nil
        diffContent = ""

        FileDiffLoader.loadDiff(for: url) { result in
            isLoading = false
            switch result {
            case let .success(output):
                diffContent = output
                error = nil
            case let .failure(loadError):
                diffContent = ""
                error = loadError.localizedDescription
            }
        }
    }
}

private struct FileDiffPlaceholder: View {
    let icon: String
    let title: String
    let message: String
    @Environment(\.mossTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme?.foreground ?? .primary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
