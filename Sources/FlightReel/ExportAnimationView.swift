import SwiftUI
import AVFoundation
import MapKit
import AppKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - Export Options

struct ExportOptions {
    var fps: Int = 30
    var resolution: ExportResolution = .p1080
    var format: VideoFormat = .mp4
    var background: ExportBackground = .map

    enum ExportResolution: String, CaseIterable, Identifiable {
        case p720 = "720p", p1080 = "1080p", p1440 = "2K", p2160 = "4K"
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .p720:  return CGSize(width: 1280,  height: 720)
            case .p1080: return CGSize(width: 1920,  height: 1080)
            case .p1440: return CGSize(width: 2560,  height: 1440)
            case .p2160: return CGSize(width: 3840,  height: 2160)
            }
        }
    }

    enum VideoFormat: String, CaseIterable, Identifiable {
        case mp4 = "MP4", mov = "MOV"
        var id: String { rawValue }
        var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
        var utType: UTType { self == .mp4 ? .mpeg4Movie : .quickTimeMovie }
        var ext: String { rawValue.lowercased() }
    }

    enum ExportBackground: String, CaseIterable, Identifiable {
        case map = "With map"
        case dark = "No background"
        var id: String { rawValue }
    }
}

// MARK: - Export Sheet

struct ExportAnimationView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var opts = ExportOptions()
    @State private var isRendering = false
    @State private var progress = 0.0
    @State private var statusText = ""
    @State private var errorMessage: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Animation")
                .font(.title2).fontWeight(.semibold)
                .padding(.bottom, 20)

            if isRendering {
                renderingView
            } else {
                settingsView
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    // MARK: Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingRow(label: "Frame Rate") {
                Picker("", selection: $opts.fps) {
                    ForEach([10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            settingRow(label: "Resolution") {
                Picker("", selection: $opts.resolution) {
                    ForEach(ExportOptions.ExportResolution.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            settingRow(label: "Format") {
                Picker("", selection: $opts.format) {
                    ForEach(ExportOptions.VideoFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Background").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $opts.background) {
                    ForEach(ExportOptions.ExportBackground.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if opts.background == .map {
                    Text(appState.mapStyle.mapyCZLayer != nil
                         ? "Mapy.cz: exports as screenshot of the current map view. Ensure the full track is visible before exporting."
                         : "Uses the currently selected map style.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Divider()

            if let track = appState.track, let dur = track.duration {
                let frames = Int(dur * Double(opts.fps))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(frames) frames · \(formatDur(dur)) video")
                        .font(.caption).foregroundStyle(.secondary)
                    if opts.background == .map {
                        Text("Render time: ~\(estimatedMinutes(frames: frames, withMap: true)) min (tiles cached after warmup)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text("Render time: ~\(estimatedMinutes(frames: frames, withMap: false)) min")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Export…") { startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.track == nil)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Rendering progress

    private var renderingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress)
            Text(statusText)
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel") {
                renderTask?.cancel()
                isRendering = false
                progress = 0
            }
            .padding(.top, 4)
        }
    }

    // MARK: Helpers

    private func settingRow<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func estimatedMinutes(frames: Int, withMap: Bool) -> String {
        let msPerFrame = withMap ? 80 : 8
        let secs = max(1, frames * msPerFrame / 1000)
        return secs < 60 ? "<1" : "\(secs / 60)"
    }

    private func formatDur(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func startExport() {
        guard let track = appState.track else { return }

        let panel = NSSavePanel()
        panel.title = "Save Animation"
        panel.allowedContentTypes = [opts.format.utType]
        let name = track.name.isEmpty ? "animation" : track.name
        panel.nameFieldStringValue = "\(name).\(opts.format.ext)"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let capturedTrack = track
        let capturedOpts  = opts
        let mapType       = appState.mapStyle.snapshotMapType

        // If a Mapy.cz style is active, capture the current map view as background.
        // The user should have the full track visible before exporting.
        let customBg:       CGImage?
        let customBgRegion: MKCoordinateRegion?
        if capturedOpts.background == .map,
           appState.mapStyle.mapyCZLayer != nil,
           let result = appState.mapSnapshotProvider?() {
            customBg       = result.0
            customBgRegion = result.1
        } else {
            customBg       = nil
            customBgRegion = nil
        }

        isRendering  = true
        errorMessage = nil
        progress     = 0

        renderTask = Task {
            do {
                let exporter = TrackExporter(track: capturedTrack, opts: capturedOpts,
                                             mapType: mapType,
                                             customBg: customBg, customBgRegion: customBgRegion)
                try await exporter.export(to: url) { pct, msg in
                    Task { @MainActor in
                        self.progress   = pct
                        self.statusText = msg
                    }
                }
                await MainActor.run {
                    isRendering = false
                    isPresented = false
                }
            } catch is CancellationError {
                await MainActor.run { isRendering = false }
            } catch {
                await MainActor.run {
                    isRendering  = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Exporter

struct TrackExporter {
    let track: GPXTrack
    let opts: ExportOptions
    let mapType: MKMapType
    let customBg: CGImage?
    let customBgRegion: MKCoordinateRegion?

    func export(to url: URL, progress: @escaping (Double, String) -> Void) async throws {
        let pts = track.points
        guard pts.count >= 2,
              let t0 = pts.first?.time,
              let t1 = pts.last?.time else { return }

        let duration = t1.timeIntervalSince(t0)
        let nFrames  = max(1, Int(duration * Double(opts.fps)))
        let size     = opts.resolution.size

        // Remove existing file
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // AVAssetWriter setup
        let writer = try AVAssetWriter(outputURL: url, fileType: opts.format.avFileType)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width) * Int(size.height) * 3
            ] as [String: Any]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey  as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.renderFailed }
        writer.startSession(atSourceTime: .zero)

        // Compute bounding region for the whole track (used for coord mapping and snapshot).
        let trackRgn = trackRegion(pts: pts)

        // Fetch the map background exactly once and immediately rasterise it to CPU memory.
        let bgImage: CGImage?
        let bgRegion: MKCoordinateRegion
        if opts.background == .map {
            if let custom = customBg {
                // Mapy.cz: use the pre-captured screenshot and its region.
                bgImage  = custom
                bgRegion = customBgRegion ?? trackRgn
            } else {
                progress(0, "Loading map…")
                bgImage  = try await snapshotCGImage(region: trackRgn, size: size)
                bgRegion = trackRgn
            }
        } else {
            bgImage  = nil
            bgRegion = trackRgn
        }

        // Render frames
        for f in 0..<nFrames {
            try Task.checkCancellation()

            let frameTime = t0.addingTimeInterval(Double(f) / Double(opts.fps))
            let pos       = interpolate(time: frameTime, pts: pts)
            let buf       = try renderFrame(pos: pos, pts: pts, upTo: frameTime,
                                            size: size, bgImage: bgImage, region: bgRegion)
            let cmTime    = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(opts.fps))

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                try Task.checkCancellation()
            }
            adaptor.append(buf, withPresentationTime: cmTime)

            progress(Double(f + 1) / Double(nFrames), "Frame \(f + 1) / \(nFrames)")
        }

        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if let err = writer.error { throw err }
    }

    // MARK: Track bounding region

    private func trackRegion(pts: [TrackPoint]) -> MKCoordinateRegion {
        let coords = pts.map(\.coordinate)
        var minLat = coords[0].latitude,  maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude:  (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta:  max(0.001, (maxLat - minLat) * 1.3),
                                   longitudeDelta: max(0.001, (maxLon - minLon) * 1.3))
        )
    }

    // MARK: Single background snapshot

    /// Fetches the map background once for the whole track.
    /// Renders via NSBitmapImageRep on the main thread — a synchronous, CPU-only
    /// path that leaves zero Metal buffer references by the time it returns.
    @MainActor
    private func snapshotCGImage(region: MKCoordinateRegion,
                                  size: CGSize) async throws -> CGImage? {
        let snapOpts = MKMapSnapshotter.Options()
        snapOpts.region  = region
        snapOpts.size    = size
        snapOpts.mapType = mapType
        let snap = try await snapshot(opts: snapOpts)

        // Draw into a plain NSBitmapImageRep (CPU bitmap) on the main thread.
        // This gives a guaranteed CPU-backed CGImage with no Metal references.
        let w = Int(size.width), h = Int(size.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = nsCtx
        snap.image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.current = prev

        return rep.cgImage   // backed by rep's malloc'd memory – no Metal deps
    }

    // MARK: Frame rendering (synchronous, CoreGraphics only, any thread)

    private func renderFrame(
        pos: CLLocationCoordinate2D,
        pts: [TrackPoint],
        upTo time: Date,
        size: CGSize,
        bgImage: CGImage?,
        region: MKCoordinateRegion
    ) throws -> CVPixelBuffer {

        // Create CVPixelBuffer.
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buf
        )
        guard let pb = buf else { throw ExportError.pixelBufferFailed }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let cgCtx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw ExportError.pixelBufferFailed }

        // CGContext writes y=0 to the first bytes of the CVPixelBuffer.
        // In H.264 video, row 0 of the pixel buffer is the visual BOTTOM of the frame,
        // so we flip the context once so that y=0 = visual bottom, y=height = visual top —
        // the standard "screen" convention for drawing.
        cgCtx.translateBy(x: 0, y: size.height)
        cgCtx.scaleBy(x: 1, y: -1)

        // --- Background ---
        // With the flipped context, CGContext.draw(_:in:) places the image's top row at
        // the visual top of the video frame — no extra transform needed.
        if let bg = bgImage {
            cgCtx.draw(bg, in: CGRect(origin: .zero, size: size))
        } else {
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1),
                          CGColor(red: 0,    green: 0,    blue: 0,    alpha: 1)] as CFArray
            let locs: [CGFloat] = [0, 1]
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs) {
                // y=0 = video top (slight blue), y=height = video bottom (black).
                cgCtx.drawLinearGradient(grad,
                                         start: CGPoint(x: 0, y: 0),
                                         end:   CGPoint(x: 0, y: size.height),
                                         options: [.drawsAfterEndLocation])
            }
        }

        // GPS → pixel: east = larger x (right).
        // After the flip, user-space y=0 = video TOP, y=height = video BOTTOM.
        // North (higher latitude) must map to smaller y so it appears at the top.
        func toPoint(_ c: CLLocationCoordinate2D) -> CGPoint {
            let nx = (c.longitude - region.center.longitude) / region.span.longitudeDelta + 0.5
            let ny = 0.5 - (c.latitude - region.center.latitude) / region.span.latitudeDelta
            return CGPoint(x: nx * size.width, y: ny * size.height)
        }

        let lw = max(2, size.width / 640)
        cgCtx.setLineCap(.round)
        cgCtx.setLineJoin(.round)

        // --- Full track (dim) ---
        if pts.count >= 2 {
            cgCtx.setStrokeColor(opts.background == .map
                ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.25)
                : CGColor(red: 0, green: 1, blue: 1, alpha: 0.15))
            cgCtx.setLineWidth(lw)
            cgCtx.beginPath()
            for (i, p) in pts.enumerated() {
                let sp = toPoint(p.coordinate)
                i == 0 ? cgCtx.move(to: sp) : cgCtx.addLine(to: sp)
            }
            cgCtx.strokePath()
        }

        // --- Travelled path (orange) ---
        let pastPts = pts.filter { $0.time <= time }
        if pastPts.count >= 2 {
            cgCtx.setStrokeColor(CGColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1))
            cgCtx.setLineWidth(lw * 1.5)
            cgCtx.beginPath()
            for (i, p) in pastPts.enumerated() {
                let sp = toPoint(p.coordinate)
                i == 0 ? cgCtx.move(to: sp) : cgCtx.addLine(to: sp)
            }
            cgCtx.strokePath()
        }

        // --- Drone marker ---
        let dp = toPoint(pos)
        let r  = max(6.0, size.width / 200)
        cgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        cgCtx.fillEllipse(in: CGRect(x: dp.x - r * 1.5, y: dp.y - r * 1.5,
                                      width: r * 3, height: r * 3))
        cgCtx.setFillColor(CGColor(red: 1, green: 0.231, blue: 0.188, alpha: 1))
        cgCtx.fillEllipse(in: CGRect(x: dp.x - r, y: dp.y - r,
                                      width: r * 2, height: r * 2))

        return pb
    }

    // MARK: MKMapSnapshotter async wrapper

    @MainActor
    private func snapshot(opts: MKMapSnapshotter.Options) async throws -> MKMapSnapshotter.Snapshot {
        try await withCheckedThrowingContinuation { cont in
            let s = MKMapSnapshotter(options: opts)
            s.start { snap, err in
                if let err  { cont.resume(throwing: err) }
                else if let snap { cont.resume(returning: snap) }
                else { cont.resume(throwing: ExportError.snapshotFailed) }
            }
        }
    }

    // MARK: Interpolation

    private func interpolate(time: Date, pts: [TrackPoint]) -> CLLocationCoordinate2D {
        guard let first = pts.first, let last = pts.last else { return CLLocationCoordinate2D() }
        if time <= first.time { return first.coordinate }
        if time >= last.time  { return last.coordinate  }
        for i in 1..<pts.count {
            guard pts[i].time >= time else { continue }
            let dt = pts[i].time.timeIntervalSince(pts[i - 1].time)
            let t  = dt > 0 ? time.timeIntervalSince(pts[i - 1].time) / dt : 0
            return CLLocationCoordinate2D(
                latitude:  pts[i-1].coordinate.latitude  + (pts[i].coordinate.latitude  - pts[i-1].coordinate.latitude)  * t,
                longitude: pts[i-1].coordinate.longitude + (pts[i].coordinate.longitude - pts[i-1].coordinate.longitude) * t
            )
        }
        return last.coordinate
    }

}

// MARK: - Errors

enum ExportError: LocalizedError {
    case renderFailed, pixelBufferFailed, snapshotFailed
    var errorDescription: String? {
        switch self {
        case .renderFailed:     return "Failed to render frame"
        case .pixelBufferFailed: return "Failed to create pixel buffer"
        case .snapshotFailed:   return "Map snapshot failed"
        }
    }
}
