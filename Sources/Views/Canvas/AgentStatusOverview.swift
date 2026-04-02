import SwiftUI

struct AgentStatusOverview: View {
    let sessions: [TerminalSession]
    var onFitSession: ((TerminalSession) -> Void)?

    @Environment(\.mossTheme) private var theme
    @State private var lastFittedIndex: Int = -1

    private var waitingSessions: [TerminalSession] {
        sessions.filter { $0.status == .waiting }
    }

    var body: some View {
        let waiting = waitingSessions
        if !waiting.isEmpty {
            Button {
                cycleNextWaiting(waiting)
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(theme.color(for: .waiting))
                        .frame(width: 6, height: 6)
                    Text("\(waiting.count) waiting")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryForeground)
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func cycleNextWaiting(_ waiting: [TerminalSession]) {
        guard !waiting.isEmpty else { return }
        let nextIndex = (lastFittedIndex + 1) % waiting.count
        lastFittedIndex = nextIndex
        onFitSession?(waiting[nextIndex])
    }
}
