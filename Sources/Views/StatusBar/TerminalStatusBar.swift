import SwiftUI

struct TaskProgressIndicator: View {
    let tasks: [TrackedTask]
    @Environment(\.mossTheme) private var theme

    private var completedCount: Int { tasks.filter(\.isDone).count }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tasks) { task in
                RoundedRectangle(cornerRadius: 2)
                    .fill(task.isDone ? Color.green : (theme?.secondaryForeground ?? .secondary).opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            Text("\(completedCount)/\(tasks.count)")
                .font(.caption2)
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                .monospacedDigit()
        }
    }
}
