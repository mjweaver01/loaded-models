import Charts
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    let monitor: Monitor
    let desktopWidget: DesktopWidgetController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ModelList(monitor: monitor)
            Divider()
            MetricChart(
                title: "Tokens/sec",
                value: monitor.lastTokensPerSecond.map { String(format: "last %.1f", $0) } ?? "—",
                points: tokenPoints,
                maxValue: niceChartMax(tokenPoints.map(\.value).max() ?? 0),
                color: .teal
            )
            MetricChart(
                title: "GPU",
                value: "\(Int(monitor.latest?.gpu ?? 0))%",
                points: monitor.samples.map { ChartPoint(id: $0.id, value: $0.gpu) },
                maxValue: 100,
                color: .green
            )
            MetricChart(
                title: "Runtime CPU",
                value: "\(Int(monitor.latest?.cpu ?? 0))%",
                points: monitor.samples.map { ChartPoint(id: $0.id, value: $0.cpu) },
                maxValue: 100,
                color: .blue
            )
            MetricChart(
                title: "GPU memory",
                value: String(format: "%.1f GB", monitor.latest?.gpuMemoryGB ?? 0),
                points: monitor.samples.map { ChartPoint(id: $0.id, value: $0.gpuMemoryGB) },
                maxValue: Double(monitor.physicalMemory) / 1_073_741_824,
                color: .orange
            )
            MemoryBar(used: monitor.systemMemoryUsed, models: monitor.modelBytes, total: monitor.physicalMemory)
            Divider()
            Footer(lmStudioRunning: monitor.lmStudioRunning, desktopWidget: desktopWidget)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var tokenPoints: [ChartPoint] { monitor.tokensPerSecondSeries }

    private var header: some View {
        HStack {
            Text("Loaded Models").font(.headline)
            Spacer()
            if monitor.anyActive {
                Label("Generating", systemImage: "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
    }
}

/// Rounds a chart's y-axis ceiling up to 1/2/5 × 10ⁿ so the scale doesn't jitter.
func niceChartMax(_ value: Double) -> Double {
    guard value > 10 else { return 10 }
    let magnitude = pow(10, floor(log10(value)))
    return [1, 2, 5, 10].map { $0 * magnitude }.first { $0 >= value } ?? value
}

struct ModelList: View {
    let monitor: Monitor

    var body: some View {
        if monitor.models.isEmpty {
            Text(monitor.runtimeRunning ? "No models loaded" : "LM Studio / Ollama not running")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 10) {
                ForEach(monitor.models) { ModelRow(model: $0, throughput: monitor.throughput(for: $0)) }
            }
        }
    }
}

struct ModelRow: View {
    let model: LoadedModel
    let throughput: ModelThroughput?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(model.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let throughput {
                    ThroughputLine(throughput: throughput)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let size = model.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory))
                        .font(.system(size: 12).monospacedDigit())
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.isActive ? .green : .secondary)
            }
        }
    }

    private var subtitle: String {
        var parts = [model.source.rawValue]
        if !model.detail.isEmpty { parts.append(model.detail) }
        if let context = model.contextLength { parts.append("\(context / 1024)k ctx") }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        if model.isActive {
            return model.queued > 0 ? "Generating (+\(model.queued))" : "Generating"
        }
        guard let lastUsed = model.lastUsed else { return "Idle" }
        return "Used " + lastUsed.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

struct ThroughputLine: View {
    let throughput: ModelThroughput

    var body: some View {
        HStack(spacing: 6) {
            Label(String(format: "%.1f tok/s", throughput.last), systemImage: "bolt.fill")
                .foregroundStyle(.teal)
            if throughput.recent.count > 1 {
                Text(String(format: "avg %.1f", throughput.average))
                Sparkline(values: throughput.recent, maxValue: (throughput.recent.max() ?? 1) * 1.1, color: .teal)
                    .frame(width: 36, height: 11)
            }
            Text(String(format: "%d tok · TTFT %.2fs", throughput.lastTokens, throughput.lastTimeToFirstToken))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct MetricChart: View {
    let title: String
    let value: String
    let points: [ChartPoint]
    let maxValue: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.monospacedDigit())
            }
            Chart(points) { point in
                AreaMark(x: .value("Time", point.id), y: .value(title, point.value))
                    .foregroundStyle(color.opacity(0.2))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.id), y: .value(title, point.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: 0...maxValue)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, maxValue / 2, maxValue]) {
                    AxisGridLine()
                }
            }
            .frame(height: 44)
        }
    }

    private var xDomain: ClosedRange<Int> {
        let last = points.last?.id ?? Monitor.historyLength
        return (last - Monitor.historyLength + 1)...last
    }
}

struct MemoryBar: View {
    let used: UInt64
    let models: UInt64
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("System memory").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(format(used)) / \(format(total))").font(.caption.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.secondary.opacity(0.5))
                        .frame(width: geo.size.width * fraction(used))
                    Capsule().fill(Color.purple)
                        .frame(width: geo.size.width * fraction(models))
                }
            }
            .frame(height: 6)
            if models > 0 {
                Text("Models: \(format(models))")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
        }
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        total == 0 ? 0 : min(1, CGFloat(value) / CGFloat(total))
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private struct Footer: View {
    let lmStudioRunning: Bool
    @Bindable var desktopWidget: DesktopWidgetController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Toggle("Desktop widget", isOn: $desktopWidget.isVisible)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            HStack {
                Spacer()
                Button(lmStudioRunning ? "LM Studio" : "Open LM Studio") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/LM Studio.app"))
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .controlSize(.small)
    }
}
