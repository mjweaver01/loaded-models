import SwiftUI

@main
struct LoadedModelsApp: App {
    @State private var monitor: Monitor
    @State private var desktopWidget: DesktopWidgetController

    init() {
        let monitor = Monitor()
        _monitor = State(initialValue: monitor)
        _desktopWidget = State(initialValue: DesktopWidgetController(monitor: monitor))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor, desktopWidget: desktopWidget)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar only accepts a single image + text, so the sparkline and count are rendered into one template image.
struct MenuBarLabel: View {
    let monitor: Monitor

    var body: some View {
        let content = MenuBarLabelContent(
            values: monitor.samples.suffix(32).map(\.gpu),
            count: monitor.models.count,
            active: monitor.anyActive
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return Image(nsImage: image)
    }
}

private struct MenuBarLabelContent: View {
    let values: [Double]
    let count: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            Sparkline(values: values, maxValue: 100)
                .frame(width: 32, height: 15)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 0.75).opacity(0.45))
            Text(active ? "\(count)•" : "\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.black)
        .padding(.vertical, 1)
    }
}

struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    var color: Color = .black

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: size.height - CGFloat(min(value, maxValue) / maxValue) * (size.height - 1.5) - 0.75
                )
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.4)))
            context.stroke(line, with: .color(color), lineWidth: 1)
        }
    }
}
