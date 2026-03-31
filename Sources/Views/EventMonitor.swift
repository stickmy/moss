import AppKit

/// A wrapper around `NSEvent.addLocalMonitorForEvents` that automatically
/// removes the monitor on `deinit`, preventing the common install/remove
/// boilerplate and leak risks.
///
/// Usage:
/// ```swift
/// @State private var monitor: EventMonitor?
///
/// .onAppear {
///     monitor = EventMonitor(.scrollWheel) { event in
///         // handle event
///         return event  // or nil to consume
///     }
/// }
/// .onDisappear { monitor = nil }
/// ```
final class EventMonitor {
    private var monitor: Any?

    init(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
