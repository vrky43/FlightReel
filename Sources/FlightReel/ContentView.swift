import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HSplitView {
            // Left panel: controls on top, lap list, stats at bottom
            VStack(spacing: 0) {
                ControlsPanel()

                if !appState.laps.isEmpty {
                    Divider()
                    LapListView()
                        .frame(minHeight: 180)
                }

                if let track = appState.track {
                    let selectedLap = appState.laps.first(where: { $0.id == appState.selectedLapID })
                    let pts   = selectedLap?.points ?? track.points
                    let label = selectedLap.map { "Lap \($0.number) Stats" } ?? "Track Stats"
                    Divider()
                    TrackStatsView(points: pts, label: label)
                }
            }
            .frame(minWidth: 290, idealWidth: 340)

            // Right panel: map
            MapViewRepresentable()
                .frame(minWidth: 320)
                .overlay(alignment: .bottomTrailing) {
                    Text("© Seznam.cz a.s. | mapy.cz")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $appState.showExportSheet) {
            ExportAnimationView(isPresented: $appState.showExportSheet)
                .environmentObject(appState)
        }
        .alert("Error", isPresented: .constant(appState.errorMessage != nil), actions: {
            Button("OK") { appState.errorMessage = nil }
        }, message: {
            Text(appState.errorMessage ?? "")
        })
    }
}
