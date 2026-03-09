import SwiftUI
import AppKit

struct ControlsPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                importSection
                mapLayerSection
                if appState.track != nil {
                    gateSection
                    detectionSection
                }
            }
            .padding()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Track info

    private var importSection: some View {
        GroupBox("Track") {
            VStack(alignment: .leading, spacing: 6) {
                if appState.isLoading {
                    ProgressView().progressViewStyle(.linear)
                } else if let track = appState.track {
                    Label(track.name.isEmpty ? "Unnamed Track" : track.name, systemImage: "map")
                        .font(.subheadline)
                    Text("\(track.points.count) points")
                        .font(.caption).foregroundStyle(.secondary)
                    if let dur = track.duration {
                        Text("Duration: \(formatDuration(dur))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Open…") { openFilePicker() }
                        .controlSize(.small)
                } else {
                    Text("Supports .gpx and .bfl / .bbl")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button("Open…") { openFilePicker() }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Open Track File"
        panel.message = "Choose a GPX or Betaflight Blackbox log file"
        panel.allowedContentTypes = [.gpx, .bfl, .bbl]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let _ = url.startAccessingSecurityScopedResource()
        let ext = url.pathExtension.lowercased()
        Task { @MainActor in
            if ext == "gpx" { appState.loadGPX(from: url) }
            else { appState.loadBlackbox(from: url) }
        }
    }

    // MARK: - Map style

    private var mapLayerSection: some View {
        GroupBox("Map Style") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $appState.mapStyle) {
                    ForEach(MapStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if appState.mapStyle.mapyCZLayer != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mapy.cz API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Paste your API key…", text: $appState.mapyCZApiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Text("Free key at developer.mapy.cz")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Gates

    private var gateSection: some View {
        VStack(spacing: 8) {
            Toggle("Same start & finish gate", isOn: $appState.sameStartStop)
                .padding(.horizontal, 2)

            GateConfigBox(
                label: "Start Gate",
                color: .green,
                index: $appState.startGateIndex,
                maxIndex: appState.maxGateIndex,
                track: appState.track,
                halfWidth: $appState.startHalfWidth,
                angleOffset: $appState.startAngleOffset
            )

            if !appState.sameStartStop {
                GateConfigBox(
                    label: "Finish Gate",
                    color: .red,
                    index: $appState.stopGateIndex,
                    maxIndex: appState.maxGateIndex,
                    track: appState.track,
                    halfWidth: $appState.stopHalfWidth,
                    angleOffset: $appState.stopAngleOffset
                )
            }
        }
    }

    // MARK: - Detection

    private var detectionSection: some View {
        GroupBox("Detection") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Count laps", isOn: $appState.lapCountingEnabled)

                if appState.lapCountingEnabled {
                    Divider()

                    Toggle("Direction filter", isOn: $appState.filterDirection)
                    Text("Only count crossings in the gate's forward direction.\nTurn off for figure-8 tracks.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Divider()

                    HStack {
                        Text("Splits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $appState.splitCount) {
                            Text("Off").tag(0)
                            ForEach([2, 3, 4, 5, 6, 8, 10], id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - GateConfigBox

/// One gate: position slider with step buttons, width slider, angle slider.
struct GateConfigBox: View {
    let label: String
    let color: Color
    @Binding var index: Double
    let maxIndex: Double
    let track: GPXTrack?
    @Binding var halfWidth: Double
    @Binding var angleOffset: Double

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // ── Position ──────────────────────────────
                HStack {
                    Text("Position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let time = currentTime {
                        Text(time)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                // Slider + step buttons
                HStack(spacing: 6) {
                    StepButton(systemImage: "chevron.left") {
                        index = max(0, index - 1)
                    }
                    .disabled(index <= 0)

                    Slider(value: $index, in: 0 ... maxIndex)
                        .tint(color)

                    StepButton(systemImage: "chevron.right") {
                        index = min(maxIndex, index + 1)
                    }
                    .disabled(index >= maxIndex)
                }

                // Point info
                HStack {
                    Text("Point \(Int(index))")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if let elev = currentElevation {
                        Text(String(format: "%.0f m asl", elev))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                // Live telemetry grid (blackbox data)
                if let pt = currentPoint, hasTelemetry(pt) {
                    Divider()
                    telemetryGrid(pt)
                }

                Divider()

                // ── Line shape ────────────────────────────
                LabeledSlider(label: "Width", value: $halfWidth,
                              range: 0.1 ... 50,
                              format: { "±\(String(format: "%.1f", $0)) m" })

                LabeledSlider(label: "Angle", value: $angleOffset,
                              range: -90 ... 90,
                              format: { "\(Int($0))°" })
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(label).font(.subheadline).fontWeight(.medium)
            }
        }
    }

    private var currentPoint: TrackPoint? { track?.points[safe: Int(index)] }
    private var currentTime: String? {
        guard let pt = currentPoint else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: pt.time)
    }
    private var currentElevation: Double? { currentPoint?.elevation }

    private func hasTelemetry(_ pt: TrackPoint) -> Bool {
        pt.speed != nil || pt.numSat != nil || pt.course != nil ||
        pt.heartRate != nil || pt.cadence != nil || pt.power != nil
    }

    @ViewBuilder
    private func telemetryGrid(_ pt: TrackPoint) -> some View {
        VStack(spacing: 3) {
            if let spd = pt.speed {
                TelemetryRow(label: "Speed", value: String(format: "%.1f km/h", spd * 3.6))
            }
            if let alt = pt.elevation {
                TelemetryRow(label: "Altitude", value: String(format: "%.0f m", alt))
            }
            if let sat = pt.numSat {
                TelemetryRow(label: "Satellites", value: "\(sat)")
            }
            if let hdg = pt.course {
                TelemetryRow(label: "Heading", value: String(format: "%.0f°", hdg))
            }
            if let hr = pt.heartRate {
                TelemetryRow(label: "Heart rate", value: String(format: "%.0f bpm", hr))
            }
            if let cad = pt.cadence {
                TelemetryRow(label: "Cadence", value: String(format: "%.0f rpm", cad))
            }
            if let pwr = pt.power {
                TelemetryRow(label: "Power", value: String(format: "%.0f W", pwr))
            }
        }
    }
}

// MARK: - TelemetryRow

struct TelemetryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2).monospacedDigit().foregroundStyle(.primary)
        }
    }
}

// MARK: - StepButton

struct StepButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}

// MARK: - LabeledSlider

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(format(value))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - UTType extension

import UniformTypeIdentifiers
extension UTType {
    static var gpx: UTType { UTType(filenameExtension: "gpx") ?? .data }
    static var bfl: UTType { UTType(filenameExtension: "bfl") ?? .data }
    static var bbl: UTType { UTType(filenameExtension: "bbl") ?? .data }
}

// MARK: - Array safe subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
