import Foundation
import CoreLocation

enum LapDetector {

    static let defaultGateHalfWidth: Double = 150.0
    static let minLapDuration:        Double = 2.0    // seconds between crossings

    // MARK: - Gate building

    /// Builds a gate centred on the track at `rawIndex`.
    /// - `halfWidth`: half-length of the gate line in metres.
    /// - `angleOffset`: degrees to rotate the gate from its natural perpendicular.
    ///   Positive = clockwise, range –90…+90.
    static func buildGate(
        track: GPXTrack,
        atIndex rawIndex: Int,
        halfWidth: Double = defaultGateHalfWidth,
        angleOffset: Double = 0
    ) -> Gate {
        let pts   = track.points
        let count = pts.count
        guard count >= 2 else {
            let c = pts[0].coordinate
            return Gate(trackIndex: 0, center: c, left: c, right: c, forwardDx: 1, forwardDy: 0)
        }

        let i      = max(1, min(count - 2, rawIndex))
        let center = pts[i].coordinate

        // Search outward for points at least 3 m apart — handles high-rate duplicate GPS data.
        let minDist = 3.0
        var prevCoord = pts[max(0, i - 1)].coordinate
        var nextCoord = pts[min(count - 1, i + 1)].coordinate

        for j in stride(from: i - 1, through: 0, by: -1) {
            if distMeters(pts[j].coordinate, center) >= minDist { prevCoord = pts[j].coordinate; break }
        }
        for j in (i + 1) ..< count {
            if distMeters(pts[j].coordinate, center) >= minDist { nextCoord = pts[j].coordinate; break }
        }

        let prevM = toMeters(coord: prevCoord, origin: center)
        let nextM = toMeters(coord: nextCoord, origin: center)
        let dx    = nextM.x - prevM.x
        let dy    = nextM.y - prevM.y
        let len   = sqrt(dx * dx + dy * dy)

        // Forward (track) direction, normalised.
        let fDx = len > 0 ? dx / len : 1.0
        let fDy = len > 0 ? dy / len : 0.0

        // Perpendicular, rotated by angleOffset.
        let θ   = angleOffset * .pi / 180
        let px  = -fDy        // natural perpendicular
        let py  =  fDx
        let rpx = px * cos(θ) - py * sin(θ)
        let rpy = px * sin(θ) + py * cos(θ)

        let left  = fromMeters((x:  rpx * halfWidth, y:  rpy * halfWidth), origin: center)
        let right = fromMeters((x: -rpx * halfWidth, y: -rpy * halfWidth), origin: center)
        return Gate(trackIndex: i, center: center, left: left, right: right,
                    forwardDx: fDx, forwardDy: fDy)
    }

    // MARK: - Split gate building

    /// Places `count` evenly-spaced split gates between `lapStartIndex` and `lapEndIndex`.
    /// Both indices are raw indices into `track.points`.
    /// Half-width is auto-shrunk for gates that are close to their neighbours.
    static func buildSplitGates(
        track: GPXTrack,
        startGate: Gate,
        stopGate: Gate,
        lapStartIndex: Int,
        lapEndIndex: Int,
        count: Int,
        maxHalfWidth: Double = 20.0,
        overrideIndices: [Double] = []
    ) -> [Gate] {
        guard count > 0, track.points.count > 2 else { return [] }

        let indices: [Int]
        if overrideIndices.count == count {
            indices = overrideIndices.map { Int($0) }
        } else {
            let lo    = min(lapStartIndex, lapEndIndex)
            let hi    = max(lapStartIndex, lapEndIndex)
            let range = hi - lo
            guard range > count else { return [] }
            indices = (1...count).map { i in
                lo + Int(Double(i) / Double(count + 1) * Double(range))
            }
        }

        // Build initial gates
        var gates = indices.map {
            buildGate(track: track, atIndex: $0, halfWidth: maxHalfWidth, angleOffset: 0)
        }

        // Auto-shrink halfWidth so lines don't overlap neighbours
        // Use both anchor gates (dedup if they're the same object by index)
        let anchors: [Gate] = startGate.trackIndex == stopGate.trackIndex
            ? [startGate]
            : [startGate, stopGate]
        for i in 0..<gates.count {
            var neighbours = anchors
            for j in 0..<gates.count where j != i { neighbours.append(gates[j]) }
            let hw = cappedHalfWidth(for: gates[i], neighbours: neighbours, max: maxHalfWidth)
            if abs(hw - maxHalfWidth) > 0.01 {
                gates[i] = buildGate(track: track, atIndex: indices[i],
                                     halfWidth: hw, angleOffset: 0)
            }
        }
        return gates
    }

    /// Returns the minimum of `max` and 38 % of the distance to the nearest neighbour.
    private static func cappedHalfWidth(for gate: Gate, neighbours: [Gate], max hw: Double) -> Double {
        var minDist = Double.infinity
        for n in neighbours { minDist = Swift.min(minDist, distMeters(gate.center, n.center)) }
        return Swift.min(hw, Swift.max(3.0, minDist * 0.38))
    }

    // MARK: - Split time calculation

    /// Returns cumulative elapsed seconds from lap start to each split gate crossing.
    /// Returns `nil` for a gate that was never crossed.
    static func computeSplitTimes(lap: Lap, splitGates: [Gate]) -> [TimeInterval?] {
        guard !splitGates.isEmpty, lap.points.count > 1 else {
            return Array(repeating: nil, count: splitGates.count)
        }
        let pts = deduplicate(lap.points)
        guard pts.count > 1 else { return Array(repeating: nil, count: splitGates.count) }

        let origin = pts[0].coordinate
        var result: [TimeInterval?] = Array(repeating: nil, count: splitGates.count)

        for (gi, sg) in splitGates.enumerated() {
            let gv = gateInMeters(sg, origin: origin)
            for i in 0..<pts.count - 1 {
                let p1 = toMeters(coord: pts[i].coordinate,     origin: origin)
                let p2 = toMeters(coord: pts[i + 1].coordinate, origin: origin)
                if intersectT(p1, p2, gv.l, gv.r) != nil {
                    result[gi] = pts[i].time.timeIntervalSince(lap.startTime)
                    break
                }
            }
        }
        return result
    }

    // MARK: - Lap detection

    /// Detects laps via precise line-segment intersection.
    /// - `filterDirection`: when true, only crossings whose travel vector has a positive
    ///   dot-product with the gate's stored forward direction are counted.
    ///   Use this to ignore approach runs from the wrong side.
    static func detect(
        track: GPXTrack,
        startGate: Gate,
        stopGate:  Gate,
        sameGate:  Bool,
        filterDirection: Bool = true
    ) -> [Lap] {
        // Deduplicate consecutive identical GPS coordinates (essential for high-rate blackbox data).
        let pts = deduplicate(track.points)
        guard pts.count > 1 else { return [] }

        let origin = pts[0].coordinate
        let sg = gateInMeters(startGate, origin: origin)
        let eg = sameGate ? sg : gateInMeters(stopGate, origin: origin)

        var laps: [Lap] = []
        var lapNumber = 1
        var lapStartTime:  Date?
        var lapStartIndex: Int?
        var waitingForStop = false
        var lastCrossingTime: Date?

        for i in 0 ..< pts.count - 1 {
            let p1 = toMeters(coord: pts[i].coordinate,     origin: origin)
            let p2 = toMeters(coord: pts[i + 1].coordinate, origin: origin)

            if !waitingForStop {
                if crosses(p1, p2, sg,
                           fDx: startGate.forwardDx, fDy: startGate.forwardDy,
                           filterDir: filterDirection) {
                    let t = pts[i].time
                    let elapsed = lastCrossingTime.map { t.timeIntervalSince($0) } ?? .infinity
                    if elapsed >= minLapDuration {
                        lapStartTime      = t
                        lapStartIndex     = i
                        lastCrossingTime  = t
                        waitingForStop    = true
                    }
                }
            } else {
                let gate  = sameGate ? sg : eg
                let fwdDx = sameGate ? startGate.forwardDx : stopGate.forwardDx
                let fwdDy = sameGate ? startGate.forwardDy : stopGate.forwardDy

                if crosses(p1, p2, gate,
                           fDx: fwdDx, fDy: fwdDy,
                           filterDir: filterDirection) {
                    let t = pts[i + 1].time
                    let elapsed = lastCrossingTime.map { t.timeIntervalSince($0) } ?? .infinity
                    if elapsed >= minLapDuration,
                       let startTime = lapStartTime,
                       let _         = lapStartIndex {
                        // Collect all original (non-decimated) points in this time window.
                        let lapPts = track.points.filter { $0.time >= startTime && $0.time <= t }
                        laps.append(Lap(number: lapNumber,
                                        startTime: startTime,
                                        endTime: t,
                                        points: lapPts))
                        lapNumber += 1
                        lastCrossingTime = t

                        if sameGate {
                            lapStartTime  = t
                            lapStartIndex = i
                            // waitingForStop stays true — next crossing ends next lap
                        } else {
                            waitingForStop = false
                            lapStartTime   = nil
                            lapStartIndex  = nil
                        }
                    }
                }
            }
        }

        return laps
    }

    // MARK: - Private helpers

    private typealias V2 = (x: Double, y: Double)
    private typealias GateV2 = (l: V2, r: V2)

    private static func gateInMeters(_ gate: Gate, origin: CLLocationCoordinate2D) -> GateV2 {
        (l: toMeters(coord: gate.left,  origin: origin),
         r: toMeters(coord: gate.right, origin: origin))
    }

    /// Returns true if segment p1→p2 crosses the gate line AND passes the direction test.
    private static func crosses(
        _ p1: V2, _ p2: V2,
        _ gate: GateV2,
        fDx: Double, fDy: Double,
        filterDir: Bool
    ) -> Bool {
        guard let _ = intersectT(p1, p2, gate.l, gate.r) else { return false }
        if filterDir {
            let crossDx = p2.x - p1.x
            let crossDy = p2.y - p1.y
            return (crossDx * fDx + crossDy * fDy) > 0
        }
        return true
    }

    /// Parametric intersection of segment p1→p2 with segment p3→p4.
    private static func intersectT(_ p1: V2, _ p2: V2, _ p3: V2, _ p4: V2) -> Double? {
        let d1x = p2.x - p1.x, d1y = p2.y - p1.y
        let d2x = p4.x - p3.x, d2y = p4.y - p3.y
        let den = d1x * d2y - d1y * d2x
        guard abs(den) > 1e-10 else { return nil }
        let t = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / den
        let u = ((p3.x - p1.x) * d1y - (p3.y - p1.y) * d1x) / den
        return (t >= 0 && t <= 1 && u >= 0 && u <= 1) ? t : nil
    }

    /// Remove consecutive track points with identical GPS coordinates.
    private static func deduplicate(_ pts: [TrackPoint]) -> [TrackPoint] {
        var result: [TrackPoint] = []
        var lastLat: Double?, lastLon: Double?
        for pt in pts {
            if pt.coordinate.latitude != lastLat || pt.coordinate.longitude != lastLon {
                result.append(pt)
                lastLat = pt.coordinate.latitude
                lastLon = pt.coordinate.longitude
            }
        }
        return result
    }

    // MARK: - Geometry

    static func distMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R   = 6_371_000.0
        let lat = (a.latitude + b.latitude) / 2 * .pi / 180
        let dx  = (b.longitude - a.longitude) * .pi / 180 * cos(lat) * R
        let dy  = (b.latitude  - a.latitude)  * .pi / 180 * R
        return sqrt(dx * dx + dy * dy)
    }

    static func toMeters(coord: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let R    = 6_371_000.0
        let lat0 = origin.latitude  * .pi / 180
        let lon0 = origin.longitude * .pi / 180
        let lat  = coord.latitude   * .pi / 180
        let lon  = coord.longitude  * .pi / 180
        return (x: R * (lon - lon0) * cos(lat0),
                y: R * (lat - lat0))
    }

    static func fromMeters(_ m: (x: Double, y: Double), origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let R    = 6_371_000.0
        let lat0 = origin.latitude  * .pi / 180
        let lon0 = origin.longitude * .pi / 180
        return CLLocationCoordinate2D(
            latitude:  (m.y / R + lat0) * 180 / .pi,
            longitude: (m.x / (R * cos(lat0)) + lon0) * 180 / .pi
        )
    }
}
