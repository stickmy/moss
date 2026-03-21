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
    @State private var pulse = false

    var body: some View {
        switch status {
        case .running:
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

        case .pending:
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)

        case .none:
            EmptyView()
        }
    }
}
