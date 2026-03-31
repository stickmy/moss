import SwiftUI

struct StatusBorder: View {
    let status: AgentStatus

    @Environment(\.mossTheme) private var theme

    var body: some View {
        Group {
            switch status {
            case .running:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.agentRunning, lineWidth: 2)
            case .waiting:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.agentWaiting, lineWidth: 3)
            case .error:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.agentError, lineWidth: 3)
            case .idle:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.agentIdle.opacity(0.5), lineWidth: 1)
            case .none:
                EmptyView()
            }
        }
        .id(status.rawValue)
    }
}
