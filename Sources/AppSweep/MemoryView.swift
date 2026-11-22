import SwiftUI

private enum MemColors {
    static let app = Color.blue
    static let wired = Color.orange
    static let compressed = Color.purple
    static let cached = Color.teal
    static let free = Color.secondary.opacity(0.25)
}

struct MemoryView: View {
    @ObservedObject var monitor = MemoryMonitor.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id("top")
                    overview
                    freeUpCard
                    topAppsCard
                }
                .padding(24)
            }
            .defaultScrollAnchor(.top)
            .onAppear {
                monitor.start()
                DispatchQueue.main.async { proxy.scrollTo("top", anchor: .top) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "memorychip.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Memory").font(.title2.bold())
                    pressureBadge
                }
                Text("\(FileSize.memory(monitor.stats.total)) installed · updates every 2 seconds")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var pressureBadge: some View {
        switch monitor.stats.pressure {
        case .normal: return Badge(text: "Pressure: Normal", color: .green)
        case .warning: return Badge(text: "Pressure: High", color: .orange)
        case .critical: return Badge(text: "Pressure: Critical", color: .red)
        }
    }

    // MARK: Overview

    private var overview: some View {
        let s = monitor.stats
        return HStack(alignment: .center, spacing: 28) {
            MemoryRing(stats: s)
                .frame(width: 170, height: 170)

            VStack(alignment: .leading, spacing: 10) {
                LegendRow(color: MemColors.app, title: "App Memory", value: s.appMemory,
                          help: "Memory apps are actively using")
                LegendRow(color: MemColors.wired, title: "Wired", value: s.wired,
                          help: "Memory macOS itself needs; can't be freed")
                LegendRow(color: MemColors.compressed, title: "Compressed", value: s.compressed,
                          help: "Memory squeezed to make room")
                LegendRow(color: MemColors.cached, title: "Cached Files", value: s.cachedFiles,
                          help: "Recently used files kept in RAM. Freeable.")
                LegendRow(color: MemColors.free, title: "Free", value: s.free, help: "Unused memory")
                Divider()
                HStack {
                    Text("Swap used").foregroundStyle(.secondary)
                    Spacer()
                    Text(FileSize.memory(s.swapUsed)).monospacedDigit()
                }
                .font(.callout)
            }
            .frame(minWidth: 230, maxWidth: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text("Memory used, last 3 minutes").font(.caption).foregroundStyle(.secondary)
                Sparkline(values: monitor.history)
                    .frame(height: 110)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Free up

    private var freeUpCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "wind")
                .font(.system(size: 28))
                .foregroundStyle(.teal)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Free Up Memory").font(.headline)
                Text("Clears **\(FileSize.memory(monitor.stats.cachedFiles))** of cached files from RAM so apps that need memory get it straight away. Your open apps and documents aren't touched. macOS will ask for your administrator password.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = monitor.lastResult {
                    Label(r.message, systemImage: r.freed > 0 ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(r.freed > 0 ? .green : .secondary)
                        .padding(.top, 2)
                }
            }
            Spacer()
            Button {
                Task { await monitor.freeUpMemory() }
            } label: {
                if monitor.isFreeing {
                    ProgressView().controlSize(.small).frame(width: 120)
                } else {
                    Label("Free Up Memory", systemImage: "sparkles").frame(minWidth: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.large)
            .disabled(monitor.isFreeing)
        }
        .padding(18)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Top apps

    private var topAppsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps Using the Most Memory").font(.headline)
                Spacer()
                Text("Quitting an app frees all of its memory").font(.caption).foregroundStyle(.secondary)
            }
            if monitor.topApps.isEmpty {
                Text("Measuring…").foregroundStyle(.secondary)
            } else {
                let maxBytes = Double(monitor.topApps.first?.bytes ?? 1)
                ForEach(monitor.topApps.prefix(10)) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.shared.icon(for: app.bundlePath))
                            .resizable()
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(app.name).lineLimit(1)
                                if app.processCount > 1 {
                                    Text("\(app.processCount) processes").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            GeometryReader { geo in
                                Capsule().fill(MemColors.app.opacity(0.7))
                                    .frame(width: max(4, geo.size.width * Double(app.bytes) / maxBytes))
                            }
                            .frame(height: 5)
                        }
                        Text(FileSize.memory(app.bytes))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Button("Quit") { monitor.quit(app) }
                            .disabled(app.bundlePath == "/System/Library/CoreServices/Finder.app")
                            .help("Asks \(app.name) to quit. It will offer to save any unsaved work.")
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(18)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Pieces

struct MemoryRing: View {
    let stats: MemoryStats

    private var segments: [(Double, Color)] {
        let t = Double(max(stats.total, 1))
        return [
            (Double(stats.appMemory) / t, MemColors.app),
            (Double(stats.wired) / t, MemColors.wired),
            (Double(stats.compressed) / t, MemColors.compressed),
            (Double(stats.cachedFiles) / t, MemColors.cached),
        ]
    }

    var body: some View {
        ZStack {
            Circle().stroke(MemColors.free, lineWidth: 18)
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                let start = segments.prefix(i).reduce(0) { $0 + $1.0 }
                Circle()
                    .trim(from: min(1, start), to: min(1, start + seg.0))
                    .stroke(seg.1, style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text("\(Int((stats.usedFraction * 100).rounded()))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("used").font(.caption).foregroundStyle(.secondary)
                Text("\(FileSize.memory(stats.used)) of \(FileSize.memory(stats.total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: stats.used)
    }
}

private struct LegendRow: View {
    let color: Color
    let title: String
    let value: UInt64
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(title).lineLimit(1).fixedSize()
            Spacer(minLength: 12)
            Text(FileSize.memory(value)).monospacedDigit().foregroundStyle(.secondary)
        }
        .help(help)
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count < 2 ? w : w * Double(i) / Double(max(values.count - 1, 1)),
                        y: h - h * v)
            }
            ZStack {
                ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                    Path { p in p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f)) }
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                }
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [MemColors.app.opacity(0.35), MemColors.app.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(MemColors.app, lineWidth: 2)
                }
            }
        }
        .padding(6)
    }
}

struct MemorySidebarRow: View {
    @ObservedObject var monitor = MemoryMonitor.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip.fill")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory")
                Text("\(FileSize.memory(monitor.stats.cachedFiles)) freeable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int((monitor.stats.usedFraction * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(monitor.stats.pressure == .normal ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 3)
        .onAppear { monitor.start() }
    }
}
