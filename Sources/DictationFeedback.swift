import AppKit

@MainActor
final class DictationFeedback {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var anchor: NSPoint?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
        ])
        panel.contentView = background
    }

    func show(_ text: String, duration: TimeInterval? = nil) {
        timer?.invalidate()
        let point = anchor ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        anchor = point
        label.stringValue = text
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(label.intrinsicContentSize.width + 28, bounds.width), height: 36)
        let origin = NSPoint(x: min(max(point.x + 16, bounds.minX), bounds.maxX - size.width),
                             y: min(max(point.y - size.height - 12, bounds.minY), bounds.maxY - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if let duration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        anchor = nil
        panel.orderOut(nil)
    }
}
