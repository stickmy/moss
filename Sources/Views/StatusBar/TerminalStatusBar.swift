import SwiftUI

struct TerminalStatusBar: View {
    @Bindable var session: TerminalSession
    @Environment(\.mossTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Label(abbreviatePath(session.workingDirectory), systemImage: "folder")
                .font(.caption)
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                .lineLimit(1)

            if let branch = session.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusIndicator(status: session.status)
                .id(session.status.rawValue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme?.surfaceBackground.opacity(0.9) ?? Color(nsColor: .controlBackgroundColor))
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

struct StatusIndicator: View {
    let status: TerminalStatus

    var body: some View {
        switch status {
        case .pending:
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)

        case .none:
            EmptyView()
        }
    }
}
