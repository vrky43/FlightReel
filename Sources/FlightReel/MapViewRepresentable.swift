import SwiftUI
import MapKit
import QuartzCore

struct MapViewRepresentable: NSViewRepresentable {
    @EnvironmentObject var appState: AppState

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = false
        map.mapType = appState.mapStyle.mkMapType

        // Register the screenshot provider so the exporter can capture Mapy.cz tiles.
        context.coordinator.ownedMapView = map
        appState.mapSnapshotProvider = { [weak map] in
            guard let mapView: MKMapView = map else { return nil }
            let bounds = mapView.bounds
            let region = mapView.region
            guard let bitmap = mapView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            mapView.cacheDisplay(in: bounds, to: bitmap)
            guard let cgImage = bitmap.cgImage else { return nil }
            return (cgImage, region)
        }

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.appState = appState

        // Map style — swap tile overlay when style or API key changes
        if c.renderedMapStyle != appState.mapStyle || c.renderedMapyCZApiKey != appState.mapyCZApiKey {
            c.renderedMapStyle     = appState.mapStyle
            c.renderedMapyCZApiKey = appState.mapyCZApiKey

            if let old = c.mapyCZTileOverlay {
                map.removeOverlay(old)
                c.mapyCZTileOverlay = nil
            }

            map.mapType = appState.mapStyle.mkMapType

            if let layer = appState.mapStyle.mapyCZLayer, !appState.mapyCZApiKey.isEmpty {
                let overlay = MapyCZTileOverlay(layer: layer, apiKey: appState.mapyCZApiKey)
                map.addOverlay(overlay, level: .aboveRoads)
                c.mapyCZTileOverlay = overlay
            }
        }

        // Track — full reset when track changes
        if c.renderedTrackID != appState.track?.id {
            c.renderedTrackID = appState.track?.id
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            c.resetRenderState()

            // Re-add the Mapy.cz tile overlay that was wiped by removeOverlays
            if let layer = appState.mapStyle.mapyCZLayer, !appState.mapyCZApiKey.isEmpty {
                let overlay = MapyCZTileOverlay(layer: layer, apiKey: appState.mapyCZApiKey)
                map.addOverlay(overlay, level: .aboveRoads)
                c.mapyCZTileOverlay = overlay
            }

            if let track = appState.track {
                var coords = track.points.map(\.coordinate)
                let polyline = TrackPolyline(coordinates: &coords, count: coords.count)
                map.addOverlay(polyline, level: .aboveLabels)
                if let region = MKCoordinateRegion(safeCoords: coords) {
                    map.setRegion(region, animated: true)
                }
            }
        }

        // ── Gates ────────────────────────────────────────────────────────────
        // Use "add new → remove old" to avoid the flash from a blank frame.
        // Annotations are kept alive and coordinate-updated (no pin-drop jitter).

        let startIdx = Int(appState.startGateIndex)
        let stopIdx  = Int(appState.stopGateIndex)
        let sameGate = appState.sameStartStop

        // Start gate
        if c.renderedStartGate        != startIdx               ||
           c.renderedStartHalfWidth   != appState.startHalfWidth ||
           c.renderedStartAngleOffset != appState.startAngleOffset {
            c.renderedStartGate        = startIdx
            c.renderedStartHalfWidth   = appState.startHalfWidth
            c.renderedStartAngleOffset = appState.startAngleOffset

            if let sg = appState.startGate {
                // Overlay: add new before removing old — no blank frame
                var coords = [sg.left, sg.right]
                let newLine = GatePolyline(coordinates: &coords, count: 2)
                newLine.isStart = true
                map.addOverlay(newLine, level: .aboveLabels)
                if let old = c.startGatePolyline { map.removeOverlay(old) }
                c.startGatePolyline = newLine

                // Annotation: remove + re-add so MapKit never animates the position change
                if let old = c.startGateAnnotation { map.removeAnnotation(old) }
                let ann = GateCenterAnnotation(coordinate: sg.center, isStart: true)
                map.addAnnotation(ann)
                c.startGateAnnotation = ann
            }
        }

        // Stop gate
        if c.renderedStopGate         != stopIdx                ||
           c.renderedSameGate         != sameGate               ||
           c.renderedStopHalfWidth    != appState.stopHalfWidth  ||
           c.renderedStopAngleOffset  != appState.stopAngleOffset {
            c.renderedStopGate        = stopIdx
            c.renderedSameGate        = sameGate
            c.renderedStopHalfWidth   = appState.stopHalfWidth
            c.renderedStopAngleOffset = appState.stopAngleOffset

            if !sameGate, let eg = appState.stopGate {
                var coords = [eg.left, eg.right]
                let newLine = GatePolyline(coordinates: &coords, count: 2)
                newLine.isStart = false
                map.addOverlay(newLine, level: .aboveLabels)
                if let old = c.stopGatePolyline { map.removeOverlay(old) }
                c.stopGatePolyline = newLine

                if let old = c.stopGateAnnotation { map.removeAnnotation(old) }
                let sann = GateCenterAnnotation(coordinate: eg.center, isStart: false)
                map.addAnnotation(sann)
                c.stopGateAnnotation = sann
            } else {
                if let old = c.stopGatePolyline { map.removeOverlay(old); c.stopGatePolyline = nil }
                if let ann = c.stopGateAnnotation { map.removeAnnotation(ann); c.stopGateAnnotation = nil }
            }
        }

        // ── Split gates ──────────────────────────────────────────────────────
        let newSplitIndices = appState.splitGates.map { $0.trackIndex }
        if c.renderedSplitIndices != newSplitIndices {
            c.renderedSplitIndices = newSplitIndices

            if c.splitPolylines.count == appState.splitGates.count {
                // Same count: update polylines (add-new-remove-old) and re-add annotations without animation
                for (i, gate) in appState.splitGates.enumerated() {
                    var coords = [gate.left, gate.right]
                    let newLine = SplitPolyline(coordinates: &coords, count: 2)
                    newLine.number = i + 1
                    map.addOverlay(newLine, level: .aboveLabels)
                    map.removeOverlay(c.splitPolylines[i])
                    c.splitPolylines[i] = newLine

                    map.removeAnnotation(c.splitAnnotations[i])
                    let newAnn = SplitCenterAnnotation(coordinate: gate.center, number: i + 1)
                    map.addAnnotation(newAnn)
                    c.splitAnnotations[i] = newAnn
                }
            } else {
                // Count changed: add new ones first, then remove old (no blank-frame flash)
                let oldPolylines   = c.splitPolylines
                let oldAnnotations = c.splitAnnotations
                c.splitPolylines   = []
                c.splitAnnotations = []

                for (i, gate) in appState.splitGates.enumerated() {
                    var coords = [gate.left, gate.right]
                    let line = SplitPolyline(coordinates: &coords, count: 2)
                    line.number = i + 1
                    map.addOverlay(line, level: .aboveLabels)
                    c.splitPolylines.append(line)

                    let ann = SplitCenterAnnotation(coordinate: gate.center, number: i + 1)
                    map.addAnnotation(ann)
                    c.splitAnnotations.append(ann)
                }

                oldPolylines.forEach   { map.removeOverlay($0) }
                oldAnnotations.forEach { map.removeAnnotation($0) }
            }
        }

        // ── Laps ─────────────────────────────────────────────────────────────
        let lapIDs     = appState.laps.map(\.id)
        let fastestID  = appState.fastestLap?.id
        let selectedID = appState.selectedLapID
        if c.renderedLapIDs != lapIDs || c.renderedFastestID != fastestID || c.renderedSelectedID != selectedID {
            c.renderedLapIDs     = lapIDs
            c.renderedFastestID  = fastestID
            c.renderedSelectedID = selectedID
            map.overlays.filter { $0 is LapPolyline }.forEach { map.removeOverlay($0) }

            for lap in appState.laps {
                var coords = lap.points.map(\.coordinate)
                let line = LapPolyline(coordinates: &coords, count: coords.count)
                line.lapID      = lap.id
                line.isFastest  = lap.id == fastestID
                line.isSelected = lap.id == selectedID
                map.addOverlay(line, level: .aboveLabels)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var appState: AppState?
        weak var ownedMapView: MKMapView?

        var renderedMapStyle:      MapStyle?
        var renderedMapyCZApiKey:  String = ""
        var mapyCZTileOverlay:     MapyCZTileOverlay?

        var renderedTrackID:    UUID?

        // Gate change-detection
        var renderedStartGate:        Int    = -1
        var renderedStopGate:         Int    = -1
        var renderedSameGate:         Bool   = true
        var renderedStartHalfWidth:   Double = -1
        var renderedStartAngleOffset: Double = .nan
        var renderedStopHalfWidth:    Double = -1
        var renderedStopAngleOffset:  Double = .nan

        // Persistent gate objects (avoids remove/add flash and pin-drop animation)
        var startGatePolyline:  GatePolyline?
        var stopGatePolyline:   GatePolyline?
        var startGateAnnotation: GateCenterAnnotation?
        var stopGateAnnotation:  GateCenterAnnotation?

        // Split gate overlays
        var splitPolylines:      [SplitPolyline]           = []
        var splitAnnotations:    [SplitCenterAnnotation]   = []
        var renderedSplitIndices: [Int]                    = []

        var renderedLapIDs:     [UUID] = []
        var renderedFastestID:  UUID?
        var renderedSelectedID: UUID?

        func resetRenderState() {
            renderedStartGate        = -1
            renderedStopGate         = -1
            renderedSameGate         = true
            renderedStartHalfWidth   = -1
            renderedStartAngleOffset = .nan
            renderedStopHalfWidth    = -1
            renderedStopAngleOffset  = .nan
            startGatePolyline        = nil
            stopGatePolyline         = nil
            startGateAnnotation      = nil
            stopGateAnnotation       = nil
            splitPolylines           = []
            splitAnnotations         = []
            renderedSplitIndices     = []
            renderedLapIDs           = []
            renderedFastestID        = nil
            renderedSelectedID       = nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let tile as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: tile)

            case let split as SplitPolyline:
                let r = MKPolylineRenderer(polyline: split)
                r.strokeColor = NSColor.systemCyan.withAlphaComponent(0.85)
                r.lineWidth = 2.5
                r.lineCap = .square
                return r

            case let gate as GatePolyline:
                let r = MKPolylineRenderer(polyline: gate)
                r.strokeColor = gate.isStart ? .systemGreen : .systemRed
                r.lineWidth = 6
                r.lineCap = .square
                return r

            case let lap as LapPolyline:
                let r = MKPolylineRenderer(polyline: lap)
                if lap.isFastest {
                    r.strokeColor = .systemYellow
                    r.lineWidth = 5
                } else if lap.isSelected {
                    r.strokeColor = .systemOrange
                    r.lineWidth = 4
                } else {
                    r.strokeColor = NSColor.systemPurple.withAlphaComponent(0.6)
                    r.lineWidth = 2
                }
                return r

            case let track as TrackPolyline:
                let r = MKPolylineRenderer(polyline: track)
                r.strokeColor = NSColor.systemBlue.withAlphaComponent(0.7)
                r.lineWidth = 2.5
                return r

            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let split = annotation as? SplitCenterAnnotation {
                let reuseID = "split-\(split.number)"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
                view.annotation        = annotation
                view.markerTintColor   = .systemCyan
                view.glyphText         = "\(split.number)"
                view.displayPriority   = .defaultHigh
                view.titleVisibility   = .hidden
                view.animatesWhenAdded = false
                view.isDraggable       = true
                return view
            }
            guard let gate = annotation as? GateCenterAnnotation else { return nil }
            let reuseID = gate.isStart ? "start-gate" : "stop-gate"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation        = annotation
            view.markerTintColor   = gate.isStart ? .systemGreen : .systemRed
            view.glyphText         = gate.isStart ? "S" : "F"
            view.displayPriority   = .required
            view.titleVisibility   = .hidden
            view.animatesWhenAdded = false
            view.isDraggable       = true
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending, let coord = view.annotation?.coordinate else { return }
            let isGate  = view.annotation is GateCenterAnnotation
            let isSplit = view.annotation is SplitCenterAnnotation
            guard isGate || isSplit else { return }

            let capturedCoord = coord
            let capturedAnnotation = view.annotation

            Task { @MainActor [weak self] in
                guard let appState = self?.appState else { return }
                let idx = appState.nearestTrackIndex(to: capturedCoord)
                if let gate = capturedAnnotation as? GateCenterAnnotation {
                    if gate.isStart { appState.moveStartGate(toTrackIndex: idx) }
                    else            { appState.moveStopGate(toTrackIndex: idx) }
                } else if let split = capturedAnnotation as? SplitCenterAnnotation {
                    appState.moveSplitGate(at: split.number - 1, toTrackIndex: idx)
                }
            }
        }
    }
}

// MARK: - Helpers

private extension MKCoordinateRegion {
    init?(safeCoords coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return nil }
        var minLat = coords[0].latitude,  maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.001, (maxLat - minLat) * 1.3),
                                    longitudeDelta: max(0.001, (maxLon - minLon) * 1.3))
        self = MKCoordinateRegion(center: center, span: span)
    }
}
