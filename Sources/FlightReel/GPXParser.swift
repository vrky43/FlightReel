import Foundation
import CoreLocation

enum GPXError: LocalizedError {
    case parseFailure(String)
    case noPoints
    case noTimestamps

    var errorDescription: String? {
        switch self {
        case .parseFailure(let msg): return "GPX parse error: \(msg)"
        case .noPoints: return "No track points found in GPX file."
        case .noTimestamps: return "GPX file has no timestamps. Lap detection requires time data."
        }
    }
}

final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [TrackPoint] = []
    private var trackName: String = ""

    // Per-point state
    private var currentLat:  Double?
    private var currentLon:  Double?
    private var currentEle:  Double?
    private var currentTime: Date?
    private var currentSpeed:    Double?
    private var currentHeartRate: Double?
    private var currentCadence:  Double?
    private var currentPower:    Double?
    private var currentText: String = ""
    private var inTrkpt = false

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(url: URL) throws -> GPXTrack {
        let data = try Data(contentsOf: url)
        let instance = GPXParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = instance
        guard xmlParser.parse() else {
            throw GPXError.parseFailure(xmlParser.parserError?.localizedDescription ?? "Unknown XML error")
        }
        guard !instance.points.isEmpty else { throw GPXError.noPoints }
        let hasTime = instance.points.contains { $0.time != .distantPast }
        guard hasTime else { throw GPXError.noTimestamps }
        return GPXTrack(name: instance.trackName, points: instance.points)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attr: [String: String] = [:]) {
        currentText = ""
        if elementName == "trkpt" {
            inTrkpt = true
            currentLat = Double(attr["lat"] ?? "")
            currentLon = Double(attr["lon"] ?? "")
            currentEle       = nil
            currentTime      = nil
            currentSpeed     = nil
            currentHeartRate = nil
            currentCadence   = nil
            currentPower     = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip namespace prefix (e.g. "gpxtpx:hr" → "hr")
        let local = elementName.components(separatedBy: ":").last ?? elementName
        switch local {
        case "name":
            if trackName.isEmpty { trackName = text }
        case "ele":
            currentEle = Double(text)
        case "time":
            currentTime = Self.iso8601.date(from: text) ?? Self.iso8601Basic.date(from: text)
        case "speed":
            if inTrkpt { currentSpeed = Double(text) }
        case "hr":
            currentHeartRate = Double(text)
        case "cad":
            currentCadence = Double(text)
        case "watts", "power":
            if currentPower == nil { currentPower = Double(text) }
        case "trkpt":
            if inTrkpt, let lat = currentLat, let lon = currentLon {
                let point = TrackPoint(
                    id: points.count,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    time: currentTime ?? .distantPast,
                    elevation: currentEle,
                    speed: currentSpeed,
                    heartRate: currentHeartRate,
                    cadence: currentCadence,
                    power: currentPower,
                    numSat: nil,
                    course: nil
                )
                points.append(point)
            }
            inTrkpt = false
        default:
            break
        }
    }
}
