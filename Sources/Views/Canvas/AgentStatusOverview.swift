import SwiftUI

struct AgentStatusOverview: View {
    let sessions: [TerminalSession]
    var onFitSession: ((TerminalSession) -> Void)?

    @Environment(\.mossTheme) private var theme
    @State private var lastFittedIndex: Int = -1
    @State private var isHovered = false
    @State private var isPulsing = false

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
                        .overlay {
                            Circle()
                                .fill(theme.color(for: .waiting).opacity(0.5))
                                .scaleEffect(isPulsing ? 2.2 : 1)
                                .opacity(isPulsing ? 0 : 0.6)
                        }
                    Text("\(waiting.count) waiting")
                        .font(.caption)
                        .foregroundStyle(isHovered ? theme.foreground : theme.secondaryForeground)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(theme.foreground.opacity(isHovered ? 0.1 : 0))
                )
                .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHovered = $0 }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
            .onDisappear { isPulsing = false }
        }
    }

    private func cycleNextWaiting(_ waiting: [TerminalSession]) {
        guard !waiting.isEmpty else { return }
        let nextIndex = (lastFittedIndex + 1) % waiting.count
        lastFittedIndex = nextIndex
        onFitSession?(waiting[nextIndex])
    }
}
