import SwiftUI
import UniformTypeIdentifiers

@main
struct FlightReelApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    openFile(appState: appState)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Export Animation…") {
                    appState.showExportSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.track == nil)
            }
        }
    }
}

private func openFile(appState: AppState) {
    let panel = NSOpenPanel()
    panel.title = "Open Track File"
    panel.message = "Choose a GPX or Betaflight Blackbox log file"
    panel.allowedContentTypes = [
        UTType(filenameExtension: "gpx") ?? .data,
        UTType(filenameExtension: "bfl") ?? .data,
        UTType(filenameExtension: "bbl") ?? .data,
    ]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    let _ = url.startAccessingSecurityScopedResource()

    let ext = url.pathExtension.lowercased()
    Task { @MainActor in
        if ext == "gpx" {
            appState.loadGPX(from: url)
        } else {
            appState.loadBlackbox(from: url)
        }
    }
}
