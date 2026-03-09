import Foundation
import CoreLocation

// MARK: - Errors

enum BFLError: LocalizedError {
    case noGPSFields
    case noGPSData

    var errorDescription: String? {
        switch self {
        case .noGPSFields:
            return "No GPS fields found in blackbox log. Enable GPS in Betaflight and ensure it is connected."
        case .noGPSData:
            return "No valid GPS fixes found. Ensure GPS had a 3D fix during the flight."
        }
    }
}

// MARK: - BFL / BBL Binary Blackbox Parser

struct BFLParser {

    // MARK: - Encoding enum

    private enum Enc {
        case signedVB, unsignedVB, neg14bit
        case tag8_8SVB, tag2_3S32, tag8_4S16, tag2_3SVar
        case null, unknown

        init(_ s: String) {
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "0", "signed_vb",   "signed":   self = .signedVB
            case "1", "unsigned_vb", "unsigned": self = .unsignedVB
            case "3", "neg_14bit":               self = .neg14bit
            case "6", "tag8_8svb":               self = .tag8_8SVB
            case "7", "tag2_3s32":               self = .tag2_3S32
            case "8", "tag8_4s16":               self = .tag8_4S16
            case "9", "null":                    self = .null
            case "10", "tag2_3svariable":        self = .tag2_3SVar
            default:                             self = .unknown
            }
        }
    }

    private struct FDef {
        var names:      [String] = []
        var predictors: [String] = []
        var encodings:  [Enc]   = []

        var fieldCount: Int { max(names.count, encodings.count) }
        func pred(_ idx: Int) -> String { idx < predictors.count ? predictors[idx] : "0" }
    }

    // MARK: - Public entry point

    static func parse(url: URL) throws -> GPXTrack {
        let data = try Data(contentsOf: url)
        var pos = 0
        var all: [TrackPoint] = []

        while pos < data.count {
            // Each session begins with lines of the form "H ..." (0x48 0x20)
            guard pos + 1 < data.count,
                  data[pos] == 0x48, data[pos + 1] == 0x20 else { pos += 1; continue }

            var gDef = FDef(), iDef = FDef(), pDef = FDef()
            var sDef = FDef(), hDef = FDef()

            while pos < data.count,
                  pos + 1 < data.count,
                  data[pos] == 0x48, data[pos + 1] == 0x20 {
                let line = readLine(data: data, pos: &pos)
                parseHeaderLine(line, g: &gDef, i: &iDef, p: &pDef,
                                s: &sDef, h: &hDef)
            }

            guard !gDef.names.isEmpty else { continue }

            let pts = decodeSession(data: data, pos: &pos,
                                    g: gDef, i: iDef, p: pDef,
                                    s: sDef, h: hDef)
            all.append(contentsOf: pts)
        }

        guard !all.isEmpty else { throw BFLError.noGPSData }

        let reindexed = all.enumerated().map { idx, pt in
            TrackPoint(id: idx, coordinate: pt.coordinate, time: pt.time,
                       elevation: pt.elevation, speed: pt.speed,
                       heartRate: nil, cadence: nil, power: nil,
                       numSat: pt.numSat, course: pt.course)
        }
        return GPXTrack(name: url.deletingPathExtension().lastPathComponent,
                        points: reindexed)
    }

    // MARK: - Header line parsing

    private static func readLine(data: Data, pos: inout Int) -> String {
        var end = pos
        while end < data.count && data[end] != 0x0A { end += 1 }
        let s = String(data: data[pos..<end], encoding: .utf8) ?? ""
        pos = end + (end < data.count ? 1 : 0)
        return s
    }

    private static func parseHeaderLine(_ line: String,
                                        g: inout FDef, i: inout FDef,
                                        p: inout FDef, s: inout FDef,
                                        h: inout FDef) {
        // "H Field G name:time,GPS_coord[0],..."
        guard line.hasPrefix("H Field "), line.count > 8 else { return }
        let rest  = line.dropFirst(8)           // "G name:..."
        let fType = rest.prefix(1)              // "G"
        let kv    = rest.dropFirst(2)           // "name:..."
        guard let colon = kv.firstIndex(of: ":") else { return }
        let key  = String(kv[kv.startIndex..<colon])
        let vals = String(kv[kv.index(after: colon)...])
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch fType {
        case "G": applyField(vals, key: key, to: &g)
        case "I": applyField(vals, key: key, to: &i)
        case "P": applyField(vals, key: key, to: &p)
        case "S": applyField(vals, key: key, to: &s)
        case "H": applyField(vals, key: key, to: &h) // GPS home frame definition
        default:  break
        }
    }

    private static func applyField(_ vals: [String], key: String, to f: inout FDef) {
        switch key {
        case "name":      f.names      = vals
        case "predictor": f.predictors = vals
        case "encoding":  f.encodings  = vals.map { Enc($0) }
        default: break
        }
    }

    // MARK: - Session decoding

    private static func decodeSession(data: Data, pos: inout Int,
                                      g: FDef, i: FDef, p: FDef,
                                      s: FDef, h: FDef) -> [TrackPoint] {
        guard let latIdx = g.names.firstIndex(of: "GPS_coord[0]"),
              let lonIdx = g.names.firstIndex(of: "GPS_coord[1]") else { return [] }

        let gTimeIdx   = g.names.firstIndex(where: { $0 == "time" })
        let altIdx     = g.names.firstIndex(of: "GPS_altitude")
        let speedIdx   = g.names.firstIndex(where: { $0.hasPrefix("GPS_speed") })
        let satIdx     = g.names.firstIndex(of: "GPS_numSat")
        let fixIdx     = g.names.firstIndex(of: "GPS_fixType")
        let courseIdx  = g.names.firstIndex(of: "GPS_ground_course")
        let iTimeIdx = i.names.firstIndex(where: { $0 == "time" })

        // GPS coord predictor: 7 = GPS_home (add home offset to stored value)
        let usesHome = g.pred(latIdx) == "7" || g.pred(latIdx) == "GPS_home"
                    || g.pred(lonIdx) == "7" || g.pred(lonIdx) == "GPS_home"

        // GPS time predictor: 10 = PREDICT_LAST_MAIN_FRAME_TIME
        let gpsTimePredIsMainFrame: Bool = {
            guard let ti = gTimeIdx else { return false }
            let p = g.pred(ti)
            return p == "10" || p == "PREDICT_LAST_MAIN_FRAME_TIME"
        }()

        // Fallback encodings if header was incomplete
        let gEncs = g.encodings.isEmpty ? [Enc](repeating: .unsignedVB, count: g.names.count) : g.encodings
        let iEncs = i.encodings.isEmpty ? [Enc](repeating: .unsignedVB, count: i.names.count) : i.encodings
        let pEncs = p.encodings.isEmpty ? [Enc](repeating: .unsignedVB, count: p.names.count) : p.encodings
        let sEncs = s.encodings.isEmpty ? [Enc](repeating: .unsignedVB, count: s.names.count) : s.encodings
        let hEncs: [Enc] = h.encodings.isEmpty
            ? [Enc](repeating: .signedVB, count: max(h.names.count, 3))
            : h.encodings

        // GPS home: set by binary 'H' frames during the session
        var homeLat: Int32 = 0
        var homeLon: Int32 = 0
        var homeValid = false

        // Last decoded I-frame time (us since log start) — used to reconstruct GPS time
        var lastMainFrameTime: UInt32 = 0
        var gpsTime: Int64 = 0   // accumulated when predictor ≠ 10

        var prevLat: Int32?
        var prevLon: Int32?
        var pts: [TrackPoint] = []

        while pos < data.count {
            let ft = data[pos]; pos += 1

            switch ft {

            // ── GPS Home frame (binary 'H' = 0x48) ─────────────────────────
            case 0x48:
                // If the next byte is 0x20 (space), this is a new text-header
                // session, not a binary GPS_home frame. Back up and stop.
                if pos < data.count && data[pos] == 0x20 {
                    pos -= 1; return pts
                }
                var hVals = [Int32](repeating: 0, count: max(hEncs.count, 3))
                decodeFields(data: data, pos: &pos, encs: hEncs, vals: &hVals)
                homeLat  = hVals[0]
                homeLon  = hVals[1]
                homeValid = true

            // ── GPS frame ──────────────────────────────────────────────────
            case 0x47:
                var gVals = [Int32](repeating: 0, count: max(gEncs.count, g.names.count))
                decodeFields(data: data, pos: &pos, encs: gEncs, vals: &gVals)

                // Reconstruct GPS timestamp
                if let ti = gTimeIdx {
                    let stored = UInt32(bitPattern: gVals[ti])
                    if gpsTimePredIsMainFrame {
                        gpsTime = Int64(lastMainFrameTime) + Int64(stored)
                    } else {
                        gpsTime += Int64(stored)
                    }
                }

                var lat = gVals[latIdx]
                var lon = gVals[lonIdx]
                if usesHome && homeValid { lat &+= homeLat; lon &+= homeLon }

                if let fi = fixIdx,  gVals[fi] == 0      { continue }
                if let si = satIdx,  gVals[si] < 4        { continue }
                if lat == prevLat && lon == prevLon        { continue }
                guard lat != 0 || lon != 0                else { continue }

                let latD = Double(lat) / 1e7
                let lonD = Double(lon) / 1e7
                guard latD >= -90, latD <= 90,
                      lonD >= -180, lonD <= 180            else { continue }

                prevLat = lat; prevLon = lon

                let date   = Date(timeIntervalSince1970: Double(gpsTime) / 1_000_000)
                let elev   = altIdx.map    { Double(gVals[$0]) / 10.0   }  // dm → m
                let speed  = speedIdx.map  { Double(gVals[$0]) / 100.0  }  // cm/s → m/s
                let sat    = satIdx.map    { Int(gVals[$0]) }
                let course = courseIdx.map { Double(gVals[$0]) / 10.0   }  // decidegrees → °

                pts.append(TrackPoint(
                    id: 0,
                    coordinate: CLLocationCoordinate2D(latitude: latD, longitude: lonD),
                    time: date, elevation: elev, speed: speed,
                    heartRate: nil, cadence: nil, power: nil,
                    numSat: sat, course: course
                ))

            // ── Intra frame ────────────────────────────────────────────────
            case 0x49:
                var iVals = [Int32](repeating: 0, count: iEncs.count)
                decodeFields(data: data, pos: &pos, encs: iEncs, vals: &iVals)
                // Track I-frame time for GPS timestamp reconstruction
                if let ti = iTimeIdx {
                    lastMainFrameTime = UInt32(bitPattern: iVals[ti])
                }

            // ── Inter (predictive) frame ───────────────────────────────────
            case 0x50:
                var dummy = [Int32](repeating: 0, count: pEncs.count)
                decodeFields(data: data, pos: &pos, encs: pEncs, vals: &dummy)

            // ── Slow frame ─────────────────────────────────────────────────
            case 0x53:
                var dummy = [Int32](repeating: 0, count: sEncs.count)
                decodeFields(data: data, pos: &pos, encs: sEncs, vals: &dummy)

            // ── Event frame ────────────────────────────────────────────────
            case 0x45:
                if pos < data.count && data[pos] == 255 {
                    // LOG_END: session is over
                    pos += 1
                    return pts
                }
                skipEvent(data: data, pos: &pos)

            // ── Extended GPS frame (Betaflight 2025.12+, type 0xDE) ─────────
            // Same GPS fields as G frame, followed by extra data we skip.
            case 0xDE:
                let deStart = pos
                var deVals = [Int32](repeating: 0, count: max(gEncs.count, g.names.count))
                decodeFields(data: data, pos: &pos, encs: gEncs, vals: &deVals)
                // Scan forward to find the next known frame type (skip extra bytes)
                let validDE: Set<UInt8> = [0x49, 0x50, 0x47, 0x48, 0x53, 0x45, 0xDE]
                var foundNext = false
                for skip in 0..<40 {
                    if pos + skip < data.count && validDE.contains(data[pos + skip]) {
                        pos += skip; foundNext = true; break
                    }
                }
                if !foundNext { pos = deStart + 1; continue }

                var deLat = deVals[latIdx]
                var deLon = deVals[lonIdx]
                if usesHome && homeValid { deLat &+= homeLat; deLon &+= homeLon }

                if let fi = fixIdx,  deVals[fi] == 0       { continue }
                if let si = satIdx,  deVals[si] < 4         { continue }
                if deLat == prevLat && deLon == prevLon      { continue }
                guard deLat != 0 || deLon != 0              else { continue }

                let deLatD = Double(deLat) / 1e7
                let deLonD = Double(deLon) / 1e7
                guard deLatD >= -90, deLatD <= 90,
                      deLonD >= -180, deLonD <= 180          else { continue }

                prevLat = deLat; prevLon = deLon

                let deDate   = Date(timeIntervalSince1970: Double(gpsTime) / 1_000_000)
                let deElev   = altIdx.map    { Double(deVals[$0]) / 10.0   }
                let deSpeed  = speedIdx.map  { Double(deVals[$0]) / 100.0  }
                let deSat    = satIdx.map    { Int(deVals[$0]) }
                let deCourse = courseIdx.map { Double(deVals[$0]) / 10.0   }

                pts.append(TrackPoint(
                    id: 0,
                    coordinate: CLLocationCoordinate2D(latitude: deLatD, longitude: deLonD),
                    time: deDate, elevation: deElev, speed: deSpeed,
                    heartRate: nil, cadence: nil, power: nil,
                    numSat: deSat, course: deCourse
                ))

            default: break  // unknown byte, already advanced by 1
            }
        }
        return pts
    }

    // MARK: - Field decoder

    private static func decodeFields(data: Data, pos: inout Int,
                                     encs: [Enc], vals: inout [Int32]) {
        var i = 0
        while i < encs.count {
            switch encs[i] {

            case .signedVB:
                if i < vals.count { vals[i] = readSignedVB(data: data, pos: &pos) }
                else { _ = readSignedVB(data: data, pos: &pos) }
                i += 1

            case .unsignedVB, .unknown:
                if i < vals.count { vals[i] = Int32(bitPattern: readUnsignedVB(data: data, pos: &pos)) }
                else { _ = readUnsignedVB(data: data, pos: &pos) }
                i += 1

            case .neg14bit:
                let v = readUnsignedVB(data: data, pos: &pos)
                if i < vals.count { vals[i] = Int32(bitPattern: ~v) }
                i += 1

            case .null:
                if i < vals.count { vals[i] = 0 }
                i += 1

            case .tag8_8SVB:
                // Count consecutive tag8_8SVB fields (up to 8)
                var n = 0
                while i + n < encs.count, n < 8 {
                    if case .tag8_8SVB = encs[i + n] { n += 1 } else { break }
                }
                if n == 1 {
                    // Single field: read signed VB directly (no header byte)
                    if i < vals.count { vals[i] = readSignedVB(data: data, pos: &pos) }
                    else { _ = readSignedVB(data: data, pos: &pos) }
                } else {
                    guard pos < data.count else { i += n; break }
                    let header = data[pos]; pos += 1
                    for k in 0..<n {
                        let v: Int32 = (header & (1 << k)) != 0
                            ? readSignedVB(data: data, pos: &pos) : 0
                        if i + k < vals.count { vals[i + k] = v }
                    }
                }
                i += n

            case .tag2_3S32:
                // Decodes exactly 3 fields. Top 2 bits of lead byte select the field format:
                //   00 → three 2-bit signed values packed in remaining 6 bits
                //   01 → three 4-bit signed values (lead nibble + one more byte)
                //   10 → three 6-bit signed values (three bytes)
                //   11 → each field is independently 8/16/24/32-bit (selectors in lower 6 bits)
                readTag2_3S32(data: data, pos: &pos, vals: &vals, at: i)
                i += 3

            case .tag8_4S16:
                // Decodes exactly 4 fields using v2 (data version ≥ 2) nibble-buffered format.
                readTag8_4S16_v2(data: data, pos: &pos, vals: &vals, at: i)
                i += 4

            case .tag2_3SVar:
                // Decodes exactly 3 fields. Each field has a 2-bit tag:
                //   0 → value is 0 (no bytes read)
                //   nonzero → read a signed VB
                guard pos < data.count else { i += 3; break }
                let tagByte = data[pos]; pos += 1
                for k in 0..<3 {
                    let tag = (Int(tagByte) >> (k * 2)) & 3
                    let v: Int32 = tag == 0 ? 0 : readSignedVB(data: data, pos: &pos)
                    if i + k < vals.count { vals[i + k] = v }
                }
                i += 3
            }
        }
    }

    // MARK: - tag2_3S32 decoder (matches blackbox-log-viewer readTag2_3S32)

    private static func readTag2_3S32(data: Data, pos: inout Int,
                                      vals: inout [Int32], at base: Int) {
        guard pos < data.count else { return }
        let lead = Int(data[pos]); pos += 1

        switch lead >> 6 {
        case 0:
            // Three 2-bit signed values packed in the low 6 bits
            if base     < vals.count { vals[base]     = signExtendN(2, (lead >> 4) & 3) }
            if base + 1 < vals.count { vals[base + 1] = signExtendN(2, (lead >> 2) & 3) }
            if base + 2 < vals.count { vals[base + 2] = signExtendN(2,  lead       & 3) }

        case 1:
            // Three 4-bit signed values: low nibble of lead + one more byte
            if base < vals.count { vals[base] = signExtendN(4, lead & 0x0F) }
            guard pos < data.count else { return }
            let b2 = Int(data[pos]); pos += 1
            if base + 1 < vals.count { vals[base + 1] = signExtendN(4, b2 >> 4) }
            if base + 2 < vals.count { vals[base + 2] = signExtendN(4, b2 & 0x0F) }

        case 2:
            // Three 6-bit signed values, one per byte (low 6 bits each)
            if base < vals.count { vals[base] = signExtendN(6, lead & 0x3F) }
            guard pos < data.count else { return }
            let b2 = Int(data[pos]); pos += 1
            if base + 1 < vals.count { vals[base + 1] = signExtendN(6, b2 & 0x3F) }
            guard pos < data.count else { return }
            let b3 = Int(data[pos]); pos += 1
            if base + 2 < vals.count { vals[base + 2] = signExtendN(6, b3 & 0x3F) }

        default: // 3: each field is independently 8/16/24/32-bit
            var lb = lead   // low 6 bits hold three 2-bit size selectors
            for k in 0..<3 {
                let sel = lb & 3; lb >>= 2
                let v: Int32
                switch sel {
                case 0:  // 8-bit signed
                    guard pos < data.count else { return }
                    v = Int32(Int8(bitPattern: data[pos])); pos += 1
                case 1:  // 16-bit signed little-endian
                    guard pos + 1 < data.count else { pos = data.count; return }
                    v = Int32(Int16(bitPattern: UInt16(data[pos]) | UInt16(data[pos+1]) << 8))
                    pos += 2
                case 2:  // 24-bit signed little-endian
                    guard pos + 2 < data.count else { pos = data.count; return }
                    let raw = Int32(data[pos]) | Int32(data[pos+1]) << 8 | Int32(data[pos+2]) << 16
                    v = raw >= 0x80_0000 ? raw - 0x100_0000 : raw
                    pos += 3
                default: // 32-bit
                    guard pos + 3 < data.count else { pos = data.count; return }
                    v = Int32(bitPattern: UInt32(data[pos])       | UInt32(data[pos+1]) << 8
                                       | UInt32(data[pos+2]) << 16 | UInt32(data[pos+3]) << 24)
                    pos += 4
                }
                if base + k < vals.count { vals[base + k] = v }
            }
        }
    }

    // MARK: - tag8_4S16 v2 decoder (matches blackbox-log-viewer readTag8_4S16_v2)
    // Used for data version ≥ 2. Nibbles are buffered across fields.

    private static func readTag8_4S16_v2(data: Data, pos: inout Int,
                                         vals: inout [Int32], at base: Int) {
        guard pos < data.count else { return }
        var selector = Int(data[pos]); pos += 1
        var nibBuf  = 0      // last byte that still has a pending low nibble
        var hasNib  = false  // whether nibBuf's low nibble is pending

        for k in 0..<4 {
            let fieldType = selector & 3; selector >>= 2
            let v: Int32
            switch fieldType {
            case 0: // zero
                v = 0

            case 1: // 4-bit nibble
                if !hasNib {
                    guard pos < data.count else { return }
                    nibBuf = Int(data[pos]); pos += 1
                    v = signExtendN(4, nibBuf >> 4)
                    hasNib = true
                } else {
                    v = signExtendN(4, nibBuf & 0x0F)
                    hasNib = false
                }

            case 2: // 8-bit signed (may straddle a nibble boundary)
                if !hasNib {
                    guard pos < data.count else { return }
                    v = Int32(Int8(bitPattern: data[pos])); pos += 1
                } else {
                    let hi = (nibBuf & 0x0F) << 4
                    guard pos < data.count else { return }
                    nibBuf = Int(data[pos]); pos += 1
                    v = Int32(Int8(bitPattern: UInt8(hi | (nibBuf >> 4))))
                    // low nibble of nibBuf still pending
                }

            default: // 16-bit signed big-endian (may straddle a nibble boundary)
                if !hasNib {
                    guard pos + 1 < data.count else { pos = data.count; return }
                    let c1 = Int(data[pos]); let c2 = Int(data[pos+1]); pos += 2
                    v = Int32(Int16(bitPattern: UInt16((c1 << 8) | c2)))
                } else {
                    guard pos + 1 < data.count else { pos = data.count; return }
                    let c1 = Int(data[pos]); let c2 = Int(data[pos+1]); pos += 2
                    v = Int32(Int16(bitPattern: UInt16(((nibBuf & 0x0F) << 12) | (c1 << 4) | (c2 >> 4))))
                    nibBuf = c2   // low nibble of c2 is the new pending nibble
                }
            }
            if base + k < vals.count { vals[base + k] = v }
        }
    }

    // Sign-extend an n-bit unsigned value to Int32
    @inline(__always)
    private static func signExtendN(_ bits: Int, _ value: Int) -> Int32 {
        let signBit = 1 << (bits - 1)
        return Int32(value >= signBit ? value - (signBit << 1) : value)
    }

    // MARK: - Event frame skip

    private static func skipEvent(data: Data, pos: inout Int) {
        guard pos < data.count else { return }
        let evt = data[pos]; pos += 1
        switch evt {
        case 0:   // SYNC_BEEP: 1 unsignedVB (beeper timestamp)
            _ = readUnsignedVB(data: data, pos: &pos)
        case 14:  // LOGGING_RESUME: 2 unsignedVBs (iteration, time)
            _ = readUnsignedVB(data: data, pos: &pos)
            _ = readUnsignedVB(data: data, pos: &pos)
        case 20:  // DISARM: 1 unsignedVB (reason)
            _ = readUnsignedVB(data: data, pos: &pos)
        case 30:  // FLIGHT_MODE: 2 unsignedVBs (flags, lastFlags)
            _ = readUnsignedVB(data: data, pos: &pos)
            _ = readUnsignedVB(data: data, pos: &pos)
        default:
            break
        }
    }

    // MARK: - VLQ helpers

    @inline(__always)
    private static func readUnsignedVB(data: Data, pos: inout Int) -> UInt32 {
        var v: UInt32 = 0, shift = 0
        while pos < data.count, shift < 35 {
            let b = data[pos]; pos += 1
            v |= UInt32(b & 0x7F) << shift; shift += 7
            if b & 0x80 == 0 { break }
        }
        return v
    }

    @inline(__always)
    private static func readSignedVB(data: Data, pos: inout Int) -> Int32 {
        let v = readUnsignedVB(data: data, pos: &pos)
        return Int32(bitPattern: (v >> 1) ^ UInt32(bitPattern: -Int32(v & 1)))
    }
}
