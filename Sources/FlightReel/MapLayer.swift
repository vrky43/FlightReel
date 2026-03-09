import MapKit

enum MapStyle: String, CaseIterable, Identifiable {
    case standard    = "Standard"
    case satellite   = "Satellite"
    case hybrid      = "Hybrid"
    case mapy        = "Mapy"
    case mapyTourist = "Tourist"

    var id: String { rawValue }

    var mkMapType: MKMapType {
        switch self {
        case .standard:              return .standard
        case .satellite:             return .satelliteFlyover
        case .hybrid:                return .hybridFlyover
        case .mapy, .mapyTourist:    return .mutedStandard
        }
    }

    /// Map type suitable for MKMapSnapshotter, which doesn't support flyover types
    /// or custom tile overlays.
    var snapshotMapType: MKMapType {
        switch self {
        case .standard:              return .standard
        case .satellite:             return .satellite
        case .hybrid:                return .hybrid
        case .mapy, .mapyTourist:    return .mutedStandard
        }
    }

    /// Mapy.cz tile layer name for the v1 API, or nil for native Apple map styles.
    var mapyCZLayer: String? {
        switch self {
        case .mapy:        return "basic"
        case .mapyTourist: return "outdoor"
        default:           return nil
        }
    }
}

// MARK: - Custom tile overlay for Mapy.cz

/// Uses the Mapy.cz v1 API: https://api.mapy.cz/v1/maptiles/{layer}/256/{z}/{x}/{y}?apikey=KEY
final class MapyCZTileOverlay: MKTileOverlay {
    init(layer: String, apiKey: String) {
        let template = "https://api.mapy.cz/v1/maptiles/\(layer)/256/{z}/{x}/{y}?apikey=\(apiKey)"
        super.init(urlTemplate: template)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
    }
}
