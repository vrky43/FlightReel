import SwiftUI
import CoreLocation
import MapKit
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: Track
    @Published var track: GPXTrack?
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: Gate position
    @Published var sameStartStop: Bool    = true
    @Published var startGateIndex: Double = 0
    @Published var stopGateIndex:  Double = 0

    // MARK: Start gate shape
    @Published var startHalfWidth:   Double = 10.0
    @Published var startAngleOffset: Double = 0.0

    // MARK: Stop gate shape (independent when sameStartStop = false)
    @Published var stopHalfWidth:   Double = 10.0
    @Published var stopAngleOffset: Double = 0.0

    // MARK: Detection
    @Published var lapCountingEnabled: Bool = true
    @Published var filterDirection: Bool = true
    @Published var splitCount: Int = 0

    // MARK: Map screenshot (set by MapViewRepresentable for Mapy.cz export)
    var mapSnapshotProvider: (() -> (CGImage, MKCoordinateRegion)?)? = nil

    var maxGateIndex: Double {
        Double(max(1, (track?.points.count ?? 2) - 1))
    }

    var startGate: Gate? {
        guard let track else { return nil }
        return LapDetector.buildGate(track: track,
                                     atIndex: Int(startGateIndex),
                                     halfWidth: startHalfWidth,
                                     angleOffset: startAngleOffset)
    }

    var stopGate: Gate? {
        if sameStartStop { return startGate }
        guard let track else { return nil }
        return LapDetector.buildGate(track: track,
                                     atIndex: Int(stopGateIndex),
                                     halfWidth: stopHalfWidth,
                                     angleOffset: stopAngleOffset)
    }

    // MARK: Laps
    @Published var splitGates: [Gate] = []
    @Published var splitIndexOverrides: [Double] = []
    @Published var laps: [Lap] = []
    @Published var selectedLapID: UUID?

    var fastestLap: Lap? { laps.min(by: { $0.duration < $1.duration }) }

    // MARK: Map
    @Published var mapStyle: MapStyle = .standard
    @Published var showExportSheet = false

    @Published var mapyCZApiKey: String = UserDefaults.standard.string(forKey: "mapyCZApiKey") ?? "" {
        didSet { UserDefaults.standard.set(mapyCZApiKey, forKey: "mapyCZApiKey") }
    }

    // MARK: - Init

    private var cancellables = Set<AnyCancellable>()

    init() {
        let posChanges = $startGateIndex
            .combineLatest($stopGateIndex, $sameStartStop)
            .map { _ in () }

        let startShapeChanges = $startHalfWidth
            .combineLatest($startAngleOffset)
            .map { _ in () }

        let stopShapeChanges = $stopHalfWidth
            .combineLatest($stopAngleOffset, $filterDirection)
            .combineLatest($splitCount)
            .combineLatest($lapCountingEnabled)
            .map { _ in () }

        Publishers.Merge3(posChanges, startShapeChanges, stopShapeChanges)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] in
                guard let self, self.track != nil else { return }
                self.detectLaps()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func loadBlackbox(from url: URL) {
        isLoading = true
        errorMessage = nil
        laps = []
        splitGates = []
        splitIndexOverrides = []
        track = nil

        Task {
            defer { isLoading = false }
            do {
                let gpx = try await Task.detached(priority: .userInitiated) {
                    try BFLParser.parse(url: url)
                }.value
                track = gpx
                let max = Double(gpx.points.count - 1)
                startGateIndex = (max * 0.1).rounded()
                stopGateIndex  = (max * 0.9).rounded()
                detectLaps()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadGPX(from url: URL) {
        isLoading = true
        errorMessage = nil
        laps = []
        splitGates = []
        splitIndexOverrides = []
        track = nil

        Task {
            defer { isLoading = false }
            do {
                let gpx = try await Task.detached(priority: .userInitiated) {
                    try GPXParser.parse(url: url)
                }.value
                track = gpx
                let max = Double(gpx.points.count - 1)
                startGateIndex = (max * 0.1).rounded()
                stopGateIndex  = (max * 0.9).rounded()
                detectLaps()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func detectLaps() {
        guard lapCountingEnabled else { laps = []; return }
        guard let track, let sg = startGate, let eg = stopGate else { return }

        // Step 1: detect laps (no splits yet)
        var detected = LapDetector.detect(track: track,
                                          startGate: sg,
                                          stopGate: eg,
                                          sameGate: sameStartStop,
                                          filterDirection: filterDirection)

        // Step 2: place split gates bounded to exactly one lap
        if splitCount > 0, let firstLap = detected.first {
            let pts  = track.points
            let si   = Int(startGateIndex)

            // For same-gate circuits, bound the range by the first detected lap's
            // end time so splits stay within one loop — not the whole recording.
            let lapEndIdx: Int
            if sameStartStop {
                lapEndIdx = pts.lastIndex(where: { $0.time <= firstLap.endTime }) ?? pts.count - 1
            } else {
                lapEndIdx = Int(stopGateIndex)
            }

            let lo    = min(si, lapEndIdx)
            let hi    = max(si, lapEndIdx)
            let maxHW = max(3.0, min(startHalfWidth * 0.55, 30.0))

            // Clear stale overrides when split count has changed
            if splitIndexOverrides.count != splitCount { splitIndexOverrides = [] }

            let splits = LapDetector.buildSplitGates(
                track: track,
                startGate: sg,
                stopGate: sameStartStop ? sg : eg,
                lapStartIndex: lo,
                lapEndIndex: hi,
                count: splitCount,
                maxHalfWidth: maxHW,
                overrideIndices: splitIndexOverrides)

            splitGates = splits

            if !splits.isEmpty {
                detected = detected.map { lap in
                    var l = lap
                    l.splitTimes = LapDetector.computeSplitTimes(lap: lap, splitGates: splits)
                    return l
                }
            }
        } else {
            splitGates = []
            splitIndexOverrides = []
        }

        laps = detected
    }

    func selectLap(_ lap: Lap) {
        selectedLapID = (selectedLapID == lap.id) ? nil : lap.id
    }

    // MARK: - Drag helpers (called from map drag delegate)

    func nearestTrackIndex(to coord: CLLocationCoordinate2D) -> Double {
        guard let track, !track.points.isEmpty else { return 0 }
        var bestIdx = 0
        var bestDist = Double.infinity
        for (i, pt) in track.points.enumerated() {
            let d = LapDetector.distMeters(coord, pt.coordinate)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return Double(bestIdx)
    }

    func moveStartGate(toTrackIndex idx: Double) {
        startGateIndex = min(maxGateIndex, max(0, idx))
        detectLaps()
    }

    func moveStopGate(toTrackIndex idx: Double) {
        stopGateIndex = min(maxGateIndex, max(0, idx))
        detectLaps()
    }

    func moveSplitGate(at splitIdx: Int, toTrackIndex trackIdx: Double) {
        guard splitIdx >= 0, splitIdx < splitCount else { return }
        if splitIndexOverrides.count != splitCount {
            splitIndexOverrides = Array(repeating: -1, count: splitCount)
        }
        splitIndexOverrides[splitIdx] = trackIdx
        detectLaps()
    }
}
