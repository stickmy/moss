import SwiftUI

struct AgentStatusOverview: View {
    let sessions: [TerminalSession]

    @Environment(\.mossTheme) private var theme

    private var statusCounts: [(AgentStatus, Int)] {
        let grouped = Dictionary(grouping: sessions, by: \.status)
        return [AgentStatus.waiting, .error, .running, .idle]
            .compactMap { status in
                guard let count = grouped[status]?.count, count > 0 else { return nil }
                return (status, count)
            }
    }

    var body: some View {
        if !statusCounts.isEmpty {
            HStack(spacing: 8) {
                ForEach(statusCounts, id: \.0) { status, count in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(theme.color(for: status))
                            .frame(width: 6, height: 6)
                        Text("\(count) \(status.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryForeground)
                    }
                }
            }
        }
    }
}
