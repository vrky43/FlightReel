import SwiftUI
import CoreLocation

struct LapListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Label("Laps", systemImage: "flag.checkered")
                    .font(.headline)
                Spacer()
                Text("\(appState.laps.count) laps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let best = appState.fastestLap {
                    Text("Best: \(best.formattedDuration)")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            

            Divider()

            // Column header
            HStack(spacing: 0) {
                Text("#").frame(width: 28, alignment: .leading)
                Spacer()
                Text("Time").frame(width: 80, alignment: .trailing)
                Text("Δ Best").frame(width: 64, alignment: .trailing)
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.background.opacity(0.5))

            Divider()

            // Lap rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.laps) { lap in
                        LapRow(
                            lap: lap,
                            isFastest: lap.id == appState.fastestLap?.id,
                            isSelected: lap.id == appState.selectedLapID,
                            delta: deltaTime(for: lap),
                            fastestSectorTimes: appState.fastestLap.map { sectorTimes(for: $0) } ?? []
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { appState.selectLap(lap) }
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(.background)
    }

    private func deltaTime(for lap: Lap) -> TimeInterval? {
        guard let best = appState.fastestLap, best.id != lap.id else { return nil }
        return lap.duration - best.duration
    }

    private func sectorTimes(for lap: Lap) -> [TimeInterval?] {
        guard !lap.splitTimes.isEmpty else { return [] }
        var result: [TimeInterval?] = []
        var prev: TimeInterval = 0
        for t in lap.splitTimes {
            if let t { result.append(t - prev); prev = t }
            else { result.append(nil) }
        }
        if let last = lap.splitTimes.last, let lt = last {
            result.append(lap.duration - lt)
        } else {
            result.append(nil)
        }
        return result
    }
}

// MARK: - LapRow

struct LapRow: View {
    let lap: Lap
    let isFastest: Bool
    let isSelected: Bool
    let delta: TimeInterval?
    let fastestSectorTimes: [TimeInterval?]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Main row ──────────────────────────────────────────────
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if isFastest {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text("\(lap.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 28, alignment: .leading)

                Spacer()

                Text(lap.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(isFastest ? .semibold : .regular)
                    .foregroundStyle(isFastest ? Color.yellow : Color.primary)
                    .frame(width: 80, alignment: .trailing)

                Group {
                    if let d = delta {
                        Text(String(format: "+%.3f", d))
                            .foregroundStyle(.red)
                    } else if isFastest {
                        Text("BEST")
                            .foregroundStyle(.green)
                            .fontWeight(.semibold)
                    } else {
                        Text("")
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            // ── Sector times ──────────────────────────────────────────
            if !lap.splitTimes.isEmpty {
                sectorTimesView
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .background(rowBackground)
    }

    // Grid of sector time chips: "S1 28.34  S2 25.78  S3 26.38"
    // Shows N splits + 1 final sector to the finish line.
    @ViewBuilder
    private var sectorTimesView: some View {
        let sectors = computedSectorTimes
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 58, maximum: 90), alignment: .leading)],
            alignment: .leading,
            spacing: 3
        ) {
            ForEach(Array(sectors.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 3) {
                    Text("S\(i + 1)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                    if let t {
                        Text(formatSplit(t))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(sectorDeltaColor(index: i, time: t))
                    } else {
                        Text("—")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // Sector times computed from cumulative splitTimes + final sector to finish
    private var computedSectorTimes: [TimeInterval?] {
        guard !lap.splitTimes.isEmpty else { return [] }
        var result: [TimeInterval?] = []
        var prev: TimeInterval = 0
        for t in lap.splitTimes {
            if let t { result.append(t - prev); prev = t }
            else { result.append(nil) }
        }
        if let last = lap.splitTimes.last, let lt = last {
            result.append(lap.duration - lt)
        } else {
            result.append(nil)
        }
        return result
    }

    // Colour the sector green/red vs fastest lap at same sector index
    private func sectorDeltaColor(index: Int, time: TimeInterval) -> Color {
        guard !isFastest else { return .primary }
        if let fastest = fastestSectorTimes[safe: index] ?? nil {
            return time <= fastest ? .green : .red
        }
        return .primary
    }

    private func formatSplit(_ t: TimeInterval) -> String {
        let s = max(0, t)
        let m  = Int(s) / 60
        let ss = Int(s) % 60
        let cs = Int((s - floor(s)) * 100)
        return m > 0
            ? String(format: "%d:%02d.%02d", m, ss, cs)
            : String(format: "%d.%02d", ss, cs)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.15)
        } else if isFastest {
            Color.yellow.opacity(0.07)
        } else {
            Color.clear
        }
    }
}

// MARK: - TrackStatsView

struct TrackStats {
    var avgSpeedKmh: Double?
    var maxSpeedKmh: Double?
    var elevGain: Double?
    var elevLoss: Double?
    var elevMin: Double?
    var elevMax: Double?
    var avgHR: Double?
    var maxHR: Double?
    var avgCadence: Double?
    var maxCadence: Double?
    var avgPower: Double?
    var maxPower: Double?

    static let empty = TrackStats()

    static func compute(from points: [TrackPoint]) -> TrackStats {
        var s = TrackStats()
        guard !points.isEmpty else { return s }

        // Speed
        let recorded = points.compactMap(\.speed).map { $0 * 3.6 }
        let speedsKmh: [Double]
        if !recorded.isEmpty {
            speedsKmh = recorded
        } else {
            var derived: [Double] = []
            for i in 1..<points.count {
                let dt: TimeInterval = points[i].time.timeIntervalSince(points[i - 1].time)
                guard dt > 0, dt < 30 else { continue }
                let R = 6_371_000.0
                let lat = (points[i - 1].coordinate.latitude + points[i].coordinate.latitude) / 2 * .pi / 180
                let dx  = (points[i].coordinate.longitude - points[i - 1].coordinate.longitude) * .pi / 180 * cos(lat) * R
                let dy  = (points[i].coordinate.latitude  - points[i - 1].coordinate.latitude)  * .pi / 180 * R
                derived.append(sqrt(dx * dx + dy * dy) / dt * 3.6)
            }
            speedsKmh = derived
        }
        if !speedsKmh.isEmpty {
            s.avgSpeedKmh = speedsKmh.reduce(0, +) / Double(speedsKmh.count)
            s.maxSpeedKmh = speedsKmh.max()
        }

        // Elevation
        let elevs = points.compactMap(\.elevation)
        if !elevs.isEmpty {
            var gain = 0.0, loss = 0.0
            for i in 1..<elevs.count {
                let d = elevs[i] - elevs[i - 1]
                if d > 0.5 { gain += d } else if d < -0.5 { loss += -d }
            }
            s.elevGain = gain
            s.elevLoss = loss
            s.elevMin  = elevs.min()
            s.elevMax  = elevs.max()
        }

        // Heart rate
        let hrs = points.compactMap(\.heartRate)
        if !hrs.isEmpty {
            s.avgHR = hrs.reduce(0, +) / Double(hrs.count)
            s.maxHR = hrs.max()
        }

        // Cadence
        let cads = points.compactMap(\.cadence)
        if !cads.isEmpty {
            s.avgCadence = cads.reduce(0, +) / Double(cads.count)
            s.maxCadence = cads.max()
        }

        // Power
        let pows = points.compactMap(\.power)
        if !pows.isEmpty {
            s.avgPower = pows.reduce(0, +) / Double(pows.count)
            s.maxPower = pows.max()
        }

        return s
    }
}

struct TrackStatsView: View {
    let points: [TrackPoint]
    let label: String

    @State private var stats: TrackStats = .empty
    // Use first point's id as a stable identity for the current points set
    private var pointsID: Int { points.first?.id ?? -1 }

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            Divider()
            statsRows.padding(10)
        }
        .background(.background)
        .task(id: pointsID) {
            let pts = points
            let computed = await Task.detached(priority: .userInitiated) {
                TrackStats.compute(from: pts)
            }.value
            stats = computed
        }
    }

    private var statsHeader: some View {
        HStack {
            Label(label, systemImage: "chart.bar.xaxis")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var statsRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let avg = stats.avgSpeedKmh {
                statRow(icon: "speedometer", label: "Speed",
                        avg: avg, max: stats.maxSpeedKmh, unit: "km/h", format: "%.1f")
            }
            if let gain = stats.elevGain {
                elevRow(gain: gain, loss: stats.elevLoss ?? 0,
                        min: stats.elevMin, max: stats.elevMax)
            }
            if let avg = stats.avgHR {
                statRow(icon: "heart.fill", label: "Heart Rate",
                        avg: avg, max: stats.maxHR, unit: "bpm", format: "%.0f", iconColor: .red)
            }
            if let avg = stats.avgCadence {
                statRow(icon: "arrow.clockwise", label: "Cadence",
                        avg: avg, max: stats.maxCadence, unit: "rpm", format: "%.0f")
            }
            if let avg = stats.avgPower {
                statRow(icon: "bolt.fill", label: "Power",
                        avg: avg, max: stats.maxPower, unit: "W", format: "%.0f", iconColor: .yellow)
            }
            if stats.avgSpeedKmh == nil && stats.elevGain == nil &&
               stats.avgHR == nil && stats.avgCadence == nil && stats.avgPower == nil {
                Text("Computing…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func elevRow(gain: Double, loss: Double, min: Double?, max: Double?) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "mountain.2.fill")
                .frame(width: 18)
                .foregroundStyle(.green)
            Text("Elevation")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading).padding(.leading, 5)
            Spacer()
            HStack(spacing: 8) {
                Label(String(format: "+%.0f m", gain), systemImage: "arrow.up").foregroundStyle(.green)
                Label(String(format: "−%.0f m", loss), systemImage: "arrow.down").foregroundStyle(.red)
                if let mn = min, let mx = max {
                    Text(String(format: "%.0f–%.0f m", mn, mx)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }

    private func statRow(icon: String, label: String,
                         avg: Double, max: Double?,
                         unit: String, format: String,
                         iconColor: Color = .accentColor) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(iconColor)
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading).padding(.leading, 5)
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    Text("avg").foregroundStyle(.tertiary)
                    Text(String(format: format, avg))
                }
                if let m = max {
                    HStack(spacing: 3) {
                        Text("max").foregroundStyle(.tertiary)
                        Text(String(format: format, m))
                    }
                }
                Text(unit).foregroundStyle(.secondary)
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }
}
