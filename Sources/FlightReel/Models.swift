import Foundation
import CoreLocation
import MapKit

// MARK: - TrackPoint

struct TrackPoint: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let time: Date
    let elevation: Double?
    let speed: Double?      // m/s (from GPX <speed> or extension)
    let heartRate: Double?  // bpm
    let cadence: Double?    // rpm
    let power: Double?      // watts
    let numSat: Int?        // GPS satellite count (blackbox only)
    let course: Double?     // ground course in degrees 0–360 (blackbox only)
}

// MARK: - GPXTrack

struct GPXTrack: Identifiable {
    let id = UUID()
    let name: String
    let points: [TrackPoint]

    var duration: TimeInterval? {
        guard let first = points.first?.time, let last = points.last?.time else { return nil }
        return last.timeIntervalSince(first)
    }
}

// MARK: - Gate

struct Gate {
    let trackIndex: Int
    let center: CLLocationCoordinate2D
    let left: CLLocationCoordinate2D
    let right: CLLocationCoordinate2D
    /// Normalized forward direction of travel at this gate (local metres).
    let forwardDx: Double
    let forwardDy: Double
}

// MARK: - Lap

struct Lap: Identifiable {
    let id = UUID()
    let number: Int
    let startTime: Date
    let endTime: Date
    let points: [TrackPoint]

    var splitTimes: [TimeInterval?] = []   // cumulative seconds from lap start to each split

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    var formattedDuration: String {
        let total = duration
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%d:%02d.%03d", minutes, seconds, ms)
    }
}

// MARK: - Overlay subclasses for type-based rendering

class TrackPolyline: MKPolyline {}

class GatePolyline: MKPolyline {
    var isStart: Bool = true
}

class LapPolyline: MKPolyline {
    var lapID: UUID = UUID()
    var isFastest: Bool = false
    var isSelected: Bool = false
}

class SplitPolyline: MKPolyline {
    var number: Int = 1
}

// MARK: - Split annotation

final class SplitCenterAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let number: Int
    init(coordinate: CLLocationCoordinate2D, number: Int) {
        self.coordinate = coordinate
        self.number = number
    }
}

// MARK: - Gate annotation (pin marker on map)

final class GateCenterAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var isStart: Bool
    init(coordinate: CLLocationCoordinate2D, isStart: Bool) {
        self.coordinate = coordinate
        self.isStart = isStart
    }
}
