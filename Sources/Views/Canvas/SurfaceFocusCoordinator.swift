import AppKit

enum SurfaceFocusCoordinator {
    static func focus(_ session: TerminalSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.mainWindow
                ?? NSApplication.shared.keyWindow
            else { return }

            var surfaceViews: [MossSurfaceView] = []
            collectSurfaceViews(in: window.contentView, into: &surfaceViews)

            let sessionSurfaces = surfaceViews.filter { $0.sessionId == session.id }

            // Prefer the active surface (last focused pane within the session)
            if let activeId = session.activeSurfaceId,
               let target = sessionSurfaces.first(where: { $0.leafId == activeId })
            {
                window.makeFirstResponder(target)
                return
            }

            // Fallback to any surface in this session
            if let first = sessionSurfaces.first {
                window.makeFirstResponder(first)
            }
        }
    }

    private static func collectSurfaceViews(
        in view: NSView?,
        into result: inout [MossSurfaceView]
    ) {
        guard let view else { return }
        if let surfaceView = view as? MossSurfaceView {
            result.append(surfaceView)
            return
        }
        for subview in view.subviews {
            collectSurfaceViews(in: subview, into: &result)
        }
    }
}
