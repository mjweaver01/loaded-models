import AppKit
import SwiftUI

/// A borderless panel that sits on the wallpaper (below normal windows) and shows live stats.
@MainActor
@Observable
final class DesktopWidgetController {
    private enum Keys {
        static let visible = "desktopWidgetVisible"
        static let position = "desktopWidgetTopLeft"
    }

    static let width: CGFloat = 320

    var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: Keys.visible)
            apply()
        }
    }

    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var topLeft: NSPoint?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(monitor: Monitor) {
        self.monitor = monitor
        isVisible = UserDefaults.standard.object(forKey: Keys.visible) as? Bool ?? true
        topLeft = UserDefaults.standard.string(forKey: Keys.position).map(NSPointFromString)
        // Scenes aren't set up yet during App.init; create the window on the next run loop turn.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        if isVisible {
            let panel = panel ?? makePanel()
            panel.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: DesktopWidgetView(monitor: monitor) { [weak self] in
            self?.isVisible = false
        })
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let start = topLeft.flatMap { point in
            NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) } ? point : nil
        } ?? defaultTopLeft()
        panel.setFrameTopLeftPoint(start)
        topLeft = start

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelMoved() }
            },
            // The panel resizes as models come and go; keep its top edge where the user put it.
            center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelResized() }
            },
        ]

        self.panel = panel
        return panel
    }

    private func panelMoved() {
        guard let panel else { return }
        let point = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        topLeft = point
        UserDefaults.standard.set(NSStringFromPoint(point), forKey: Keys.position)
    }

    private func panelResized() {
        guard let panel, let topLeft, NSPoint(x: panel.frame.minX, y: panel.frame.maxY) != topLeft else { return }
        panel.setFrameTopLeftPoint(topLeft)
        panel.invalidateShadow()
    }

    private func defaultTopLeft() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: frame.maxX - Self.width - 24, y: frame.maxY - 24)
    }
}

struct DesktopWidgetView: View {
    let monitor: Monitor
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loaded Models").font(.headline)
                Spacer()
                if monitor.anyActive {
                    Label("Generating", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            ModelList(monitor: monitor)
            HStack(spacing: 14) {
                let tokens = monitor.tokensPerSecondSeries
                MetricChart(
                    title: "Tokens/sec",
                    value: monitor.lastTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—",
                    points: tokens,
                    maxValue: niceChartMax(tokens.map(\.value).max() ?? 0),
                    color: .teal
                )
                MetricChart(
                    title: "GPU",
                    value: "\(Int(monitor.latest?.gpu ?? 0))%",
                    points: monitor.samples.map { ChartPoint(id: $0.id, value: $0.gpu) },
                    maxValue: 100,
                    color: .green
                )
            }
            MemoryBar(used: monitor.systemMemoryUsed, models: monitor.modelBytes, total: monitor.physicalMemory)
        }
        .padding(16)
        .frame(width: DesktopWidgetController.width)
        .background(VisualEffectBackground(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .contextMenu {
            Button("Hide Desktop Widget", action: onHide)
        }
    }
}

/// Blurs the wallpaper behind the widget, like native desktop widgets.
private struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
