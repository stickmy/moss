import SwiftUI
import AppKit

struct StableTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession
    let leafId: UUID
    let isActive: Bool

    func makeNSView(context: Context) -> MossSurfaceHostView {
        let surfaceView = session.surfaceView(for: leafId)
        let hostView = session.surfaceHostView(for: leafId)
        surfaceView.leafId = leafId
        surfaceView.isActive = isActive
        surfaceView.isHidden = !isActive
        splitDebugLog(
            "StableTerminalWrapper.makeNSView leaf=\(leafId) " +
            "host=\(debugObjectID(hostView)) surface=\(debugObjectID(surfaceView)) active=\(isActive)"
        )
        return hostView
    }

    func updateNSView(_ nsView: MossSurfaceHostView, context: Context) {
        let surfaceView = session.surfaceView(for: leafId)
        nsView.setSurfaceView(surfaceView)
        surfaceView.leafId = leafId
        surfaceView.isActive = isActive
        surfaceView.isHidden = !isActive
        splitDebugLog(
            "StableTerminalWrapper.updateNSView leaf=\(leafId) " +
            "host=\(debugObjectID(nsView)) surface=\(debugObjectID(surfaceView)) " +
            "active=\(isActive) hidden=\(!isActive)"
        )
    }
}

@MainActor
final class MossSurfaceHostView: NSView {
    private(set) var surfaceView: MossSurfaceView

    override var isOpaque: Bool { false }

    init(surfaceView: MossSurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        commonInit()
        setSurfaceView(surfaceView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func commonInit() {}

    override func layout() {
        super.layout()
        if surfaceView.frame != bounds {
            surfaceView.frame = bounds
            splitDebugLog(
                "MossSurfaceHostView.layout host=\(debugObjectID(self)) " +
                "surface=\(debugObjectID(surfaceView)) bounds=\(debugRect(bounds))"
            )
        }
    }

    func setSurfaceView(_ view: MossSurfaceView) {
        if surfaceView === view {
            attachSurfaceView()
            return
        }

        surfaceView.removeFromSuperview()
        surfaceView = view
        splitDebugLog(
            "MossSurfaceHostView.setSurfaceView host=\(debugObjectID(self)) " +
            "surface=\(debugObjectID(view))"
        )
        attachSurfaceView()
    }

    private func attachSurfaceView() {
        if surfaceView.superview !== self {
            surfaceView.removeFromSuperview()
            addSubview(surfaceView)
            splitDebugLog(
                "MossSurfaceHostView.attachSurfaceView host=\(debugObjectID(self)) " +
                "surface=\(debugObjectID(surfaceView)) superview=\(String(describing: type(of: surfaceView.superview)))"
            )
        }
        surfaceView.autoresizingMask = [.width, .height]
        surfaceView.frame = bounds
    }
}
