import SwiftUI
import Charts

/// The single "Resources" container: capacity (always shown) with live usage overlaid as percent
/// rings + a usage-over-time chart (cloud), the power state, an Upgrade entry, and Restart. Live
/// usage starts from the known capacity so there's no separate monitor container.
struct WorkspaceResourcesView: View {
    let model: WorkspaceModel
    @State private var metrics: WorkspaceMetricsModel
    @State private var busy = false
    @State private var showUpgrade = false
    @State private var showChart = false
    @State private var skeletonPulse = false

    init(model: WorkspaceModel) {
        self.model = model
        _metrics = State(initialValue: WorkspaceMetricsModel(workspace: model.workspace))
    }

    private var hasLive: Bool { model.caps.metrics }

    var body: some View {
        Section {
            // Hide the separator under Status so the only divider in this block is above Upgrade.
            LabeledContent(t("agentSettings.row.status")) { powerState }
                .listRowSeparator(.hidden)

            if hasLive {
                // Rings + chart are ONE row (no separator between them); the row's native bottom
                // separator becomes the divider above the Upgrade row.
                VStack(spacing: 0) {
                    rings
                    if showChart {
                        // Opens instantly; shows a skeleton until enough samples arrive (no freeze).
                        if metrics.history.count > 1 {
                            chart
                        } else if metrics.phase == .unavailable {
                            Text(t("workspace.monitor.unavailable")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            chartSkeleton
                        }
                    }
                }
            } else {
                // Self-hosted: no live stream — show the configured capacity statically.
                LabeledContent(t("workspace.cpu"), value: model.resources.map { "\($0.cpus)" } ?? "—")
                LabeledContent(t("workspace.memory"), value: model.resources.map { gb($0.memoryMb) } ?? "—")
                LabeledContent(t("workspace.disk"), value: model.resources.map { gb($0.diskMb) } ?? "—")
            }

            // Capability-gated: cloud workspaces can resize; a self-hosted server's hardware can't.
            // Its native top separator (the metrics row's bottom) is the divider above Upgrade.
            if model.caps.resizable {
                upgradeRow
            }
        } header: {
            HStack {
                Text(t("workspace.resources.title"))
                Spacer()
                // Small icon (not a full row) to reveal the usage-over-time chart. Always available
                // when live so the press is instant; the chart area shows a skeleton until data.
                if hasLive {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { showChart.toggle() } } label: {
                        AppIcon(.chartLine)
                            .foregroundStyle(showChart ? Palette.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("workspace.monitor.chartTitle"))
                }
            }
        }
        .task { if hasLive { metrics.start() } }
        .onDisappear { metrics.stop() }
        .sheet(isPresented: $showUpgrade) {
            WorkspaceResourcesEditView(
                current: model.resources ?? WorkspaceResources(cpus: 2, memoryMb: 2048, diskMb: 20480),
                requiresRestart: model.status?.power == .running, errorMessage: { model.error }
            ) { patch in
                await model.updateResources(patch)
            }
        }
    }

    // MARK: Rings (usage % live; capacity always in the caption)

    private var rings: some View {
        let s = metrics.latest
        let r = model.resources
        return HStack(alignment: .top, spacing: Spacing.sm) {
            ring(t("workspace.cpu"), fill: s.map { $0.cpuPercent / 100 },
                 center: s.map { "\(Int($0.cpuPercent))%" } ?? "—",
                 caption: r.map { "\($0.cpus) vCPU" } ?? "—", tint: .green)
            ring(t("workspace.memory"), fill: s.map { $0.memoryPercent / 100 },
                 center: s.map { "\(Int($0.memoryPercent))%" } ?? "—",
                 caption: memoryCaption(s, r), tint: .blue)
            ring(t("workspace.disk"), fill: s.map { $0.diskPercent / 100 },
                 center: s.map { "\(Int($0.diskPercent))%" } ?? "—",
                 caption: r.map { gb($0.diskMb) } ?? "—", tint: BotColor.amber.fill)
            ring(t("workspace.traffic"), fill: trafficFill,
                 center: trafficCenter, caption: t("workspace.traffic.caption"), tint: .purple)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }

    /// `fill` is 0…1 (nil = empty); `center` is the value shown inside the ring.
    private func ring(_ label: String, fill: Double?, center: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 8) {   // breathing room between the circle and its labels
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(max(fill ?? 0, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fill)
                Text(center).font(.caption.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            }
            .frame(width: 52, height: 52)
            VStack(spacing: 1) {
                Text(label).font(.caption2.weight(.medium)).lineLimit(1)
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Traffic ring helpers

    /// Throughput as a soft fraction of a 100 Mbps reference (purely for the ring fill).
    private var trafficFill: Double? {
        metrics.trafficKbps.map { min($0 / 12_800, 1) }
    }

    private var trafficCenter: String {
        guard let kbps = metrics.trafficKbps else { return "—" }
        return kbps >= 1024 ? String(format: "%.1fM", kbps / 1024) : "\(Int(kbps))K"
    }

    private func memoryCaption(_ s: WorkspaceStatsSample?, _ r: WorkspaceResources?) -> String {
        if let s, s.memoryTotalMb > 0 {
            return "\(gbD(s.memoryUsedMb)) / \(gbD(s.memoryTotalMb)) GB"
        }
        return r.map { gb($0.memoryMb) } ?? "—"
    }

    // MARK: Chart

    private struct Point: Identifiable {
        let id = UUID(); let t: Int; let value: Double; let metric: String
    }

    private var points: [Point] {
        metrics.history.enumerated().flatMap { index, s in
            [Point(t: index, value: s.cpuPercent, metric: t("workspace.cpu")),
             Point(t: index, value: s.memoryPercent, metric: t("workspace.memory"))]
        }
    }

    private var chart: some View {
        Chart(points) { point in
            AreaMark(x: .value("t", point.t), y: .value("%", point.value))
                .foregroundStyle(by: .value("metric", point.metric))
                .interpolationMethod(.monotone)
                .opacity(0.12)
            LineMark(x: .value("t", point.t), y: .value("%", point.value))
                .foregroundStyle(by: .value("metric", point.metric))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartForegroundStyleScale([t("workspace.cpu"): Palette.accent, t("workspace.memory"): Color(white: 0.6)])
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(position: .bottom, spacing: Spacing.sm)
        .frame(height: 120)
        .padding(.top, Spacing.xs)
    }

    /// Loading placeholder shown the instant the chart is opened, until samples arrive.
    private var chartSkeleton: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(height: 120)
            .overlay(
                VStack(spacing: 26) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.05)).frame(height: 2)
                    }
                }.padding(20)
            )
            .overlay(Text(t("workspace.monitor.connecting")).font(.caption).foregroundStyle(.secondary))
            .opacity(skeletonPulse ? 1 : 0.5)
            .padding(.top, Spacing.xs)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { skeletonPulse = true }
            }
    }

    // MARK: Rows

    private var upgradeRow: some View {
        Button { showUpgrade = true } label: {
            HStack {
                Label(t("workspace.resources.upgrade"), icon: .arrowUpCircle)
                Spacer()
                AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .disabled(busy || model.updatingResources || model.management?.isBusy == true || model.powerAction != nil)
    }

    /// Stopped is a normal VM state, not a connection failure.
    @ViewBuilder
    private var powerState: some View {
        switch model.status?.power {
        case .running:
            Text(t("detail.status.online")).foregroundStyle(.secondary)
        case .starting, .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(t("detail.status.checking")).foregroundStyle(.secondary)
            }
        case .stopped:
            Text(t("workspace.power.stopped")).foregroundStyle(.secondary)
        case .unknown, nil:
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func gb(_ mb: Int) -> String { "\(Int((Double(mb) / 1024).rounded())) GB" }
    private func gbD(_ mb: Double) -> String { String(format: "%.1f", mb / 1024) }
}
