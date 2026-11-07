import Foundation

struct MP4AudioStream {
    enum Event {
        case initialization(Data)
        case fragment(Fragment)
    }
    struct Fragment {
        let data: Data
        let start: Double
        let duration: Double
    }

    private struct Box {
        let type: String
        let start: Int
        let payload: Int
        let end: Int
    }

    private(set) var timescale: UInt32?
    private(set) var trackID: UInt32?
    private(set) var defaultSampleDuration: UInt32?
    private(set) var hasClearJOC = false
    private var sequence: UInt32?
    private var lastEnd: UInt64?
    private var pending = Data()
    private var initialization = Data()
    private var fragmentBytes = Data()
    private var fragmentPrefix = Data()
    private var collectingFragment = false

    mutating func append(_ bytes: Data) throws -> [Event] {
        pending.append(bytes)
        guard pending.count <= 16 * 1024 * 1024 else { throw failure("MP4 append buffer limit exceeded") }
        var result: [Event] = []
        while let box = try boxes(in: pending, from: 0, to: pending.count, allowPartial: true).first {
            let raw = pending.subdata(in: box.start..<box.end)
            pending.removeSubrange(0..<box.end)
            if collectingFragment {
                fragmentBytes.append(raw)
                if fragmentBytes.count > 16 * 1024 * 1024 { throw failure("MP4 assembled segment limit exceeded") }
                if box.type == "mdat" {
                    result.append(.fragment(try parseFragment(fragmentBytes)))
                    fragmentBytes.removeAll(keepingCapacity: true); collectingFragment = false
                } else if box.type == "moof" {
                    throw failure("Nested MP4 fragment")
                }
            } else if box.type == "moof" {
                guard timescale != nil else { throw failure("MP4 initialization segment missing") }
                collectingFragment = true; fragmentBytes = fragmentPrefix; fragmentBytes.append(raw); fragmentPrefix.removeAll(keepingCapacity: true)
                if fragmentBytes.count > 16 * 1024 * 1024 { throw failure("MP4 assembled segment limit exceeded") }
            } else if box.type == "mdat" {
                throw failure("MP4 media data without fragment header")
            } else if timescale != nil, ["styp", "emsg", "prft"].contains(box.type) {
                fragmentPrefix.append(raw)
                if fragmentPrefix.count > 1024 * 1024 { throw failure("MP4 fragment metadata limit exceeded") }
            } else {
                guard result.count < 64 else { throw failure("Too many MP4 boxes in append") }
                initialization.append(raw)
                if initialization.count > 2 * 1024 * 1024 { throw failure("MP4 initialization segment limit exceeded") }
                if timescale == nil, box.type == "moov" {
                    try inspectInitialization(initialization)
                    result.append(.initialization(initialization))
                }
            }
        }
        return result
    }

    mutating func inspectInitialization(_ data: Data) throws {
        let top = try boxes(in: data, from: 0, to: data.count, allowPartial: false)
        guard top.contains(where: { $0.type == "ftyp" }), let moov = top.first(where: { $0.type == "moov" }) else {
            throw failure("Invalid MP4 initialization segment")
        }
        let moovChildren = try boxes(in: data, from: moov.payload, to: moov.end, allowPartial: false)
        guard moovChildren.filter({ $0.type == "trak" }).count == 1,
              !moovChildren.contains(where: { $0.type == "pssh" }) else { throw failure("Unsupported or protected track layout") }
        var foundScale: UInt32?, foundTrack: UInt32?, foundTrex: UInt32?, foundJOC = false
        var audioTracks = 0
        for trak in moovChildren where trak.type == "trak" {
            let children = try boxes(in: data, from: trak.payload, to: trak.end, allowPartial: false)
            guard !children.contains(where: { $0.type == "edts" }) else { throw failure("Edited audio timelines are unsupported") }
            guard let mdia = children.first(where: { $0.type == "mdia" }) else { continue }
            let mdiaBoxes = try boxes(in: data, from: mdia.payload, to: mdia.end, allowPartial: false)
            guard let mdhd = mdiaBoxes.first(where: { $0.type == "mdhd" }), let hdlr = mdiaBoxes.first(where: { $0.type == "hdlr" }) else { continue }
            guard hdlr.payload + 12 <= hdlr.end else { throw failure("Truncated audio handler") }
            let handler = try fourCC(data, at: hdlr.payload + 8)
            guard handler == "soun" else { continue }
            audioTracks += 1
            guard audioTracks == 1, mdhd.payload < mdhd.end else { throw failure("Unsupported MP4 audio track layout") }
            let version = data[mdhd.payload]
            guard mdhd.payload + (version == 1 ? 24 : 16) <= mdhd.end, hdlr.payload + 12 <= hdlr.end else { throw failure("Truncated MP4 audio timing metadata") }
            let scaleOffset = mdhd.payload + (version == 1 ? 20 : 12)
            let scale = try u32(data, at: scaleOffset)
            guard scale > 0, let tkhd = children.first(where: { $0.type == "tkhd" }), tkhd.payload < tkhd.end else { throw failure("Invalid MP4 audio timing metadata") }
            guard tkhd.payload + (data[tkhd.payload] == 1 ? 24 : 16) <= tkhd.end else { throw failure("Truncated MP4 track metadata") }
            foundScale = scale
            foundTrack = try u32(data, at: tkhd.payload + (data[tkhd.payload] == 1 ? 20 : 12))
            guard let minf = mdiaBoxes.first(where: { $0.type == "minf" }) else { throw failure("MP4 audio sample description missing") }
            let minfBoxes = try boxes(in: data, from: minf.payload, to: minf.end, allowPartial: false)
            guard let stbl = minfBoxes.first(where: { $0.type == "stbl" }) else { throw failure("MP4 audio sample description missing") }
            let stblBoxes = try boxes(in: data, from: stbl.payload, to: stbl.end, allowPartial: false)
            guard let stsd = stblBoxes.first(where: { $0.type == "stsd" }) else { throw failure("MP4 audio sample description missing") }
            let entries = try boxes(in: data, from: stsd.payload + 8, to: stsd.end, allowPartial: false)
            guard entries.count == 1, entries[0].type == "ec-3" else { throw failure("Unsupported MP4 audio codec") }
            foundJOC = try inspectEC3Entry(data, entry: entries[0])
            guard foundJOC else { throw failure("Clear E-AC-3 JOC audio is required") }
        }
        guard let scale = foundScale, let id = foundTrack else { throw failure("MP4 audio track missing") }
        for mvex in moovChildren where mvex.type == "mvex" {
            for trex in try boxes(in: data, from: mvex.payload, to: mvex.end, allowPartial: false) where trex.type == "trex" {
                if try u32(data, at: trex.payload + 4) == id { foundTrex = try u32(data, at: trex.payload + 12) }
            }
        }
        timescale = scale; trackID = id; defaultSampleDuration = foundTrex; hasClearJOC = foundJOC
    }

    mutating func parseFragment(_ data: Data) throws -> Fragment {
        guard let timescale, let trackID, hasClearJOC else { throw failure("MP4 initialization segment not ready") }
        let top = try boxes(in: data, from: 0, to: data.count, allowPartial: false)
        guard let moof = top.first(where: { $0.type == "moof" }), top.contains(where: { $0.type == "mdat" }),
              !top.contains(where: { ["pssh", "senc", "saiz", "saio", "sinf", "encv", "enca"].contains($0.type) }) else {
            throw failure("Invalid or protected MP4 fragment")
        }
        let children = try boxes(in: data, from: moof.payload, to: moof.end, allowPartial: false)
        guard let mfhd = children.first(where: { $0.type == "mfhd" }),
              let traf = children.first(where: { $0.type == "traf" }) else { throw failure("MP4 fragment timing missing") }
        guard children.filter({ $0.type == "traf" }).count == 1, mfhd.payload + 8 <= mfhd.end else { throw failure("Unsupported fragment layout") }
        let seq = try u32(data, at: mfhd.payload + 4)
        if let previous = sequence, seq != previous &+ 1 { throw failure("MP4 fragment sequence discontinuity") }
        let trafBoxes = try boxes(in: data, from: traf.payload, to: traf.end, allowPartial: false)
        guard !trafBoxes.contains(where: { ["senc", "saiz", "saio", "sinf", "tenc", "pssh"].contains($0.type) }),
              let tfhd = trafBoxes.first(where: { $0.type == "tfhd" }), let tfdt = trafBoxes.first(where: { $0.type == "tfdt" }) else { throw failure("Invalid or protected MP4 fragment") }
        let truns = trafBoxes.filter { $0.type == "trun" }
        guard !truns.isEmpty else { throw failure("MP4 fragment timing missing") }
        guard tfhd.payload + 8 <= tfhd.end, tfdt.payload + 8 <= tfdt.end else { throw failure("Truncated MP4 fragment timing") }
        let tfhdFlags = try u24(data, at: tfhd.payload + 1)
        guard tfhdFlags & 0x000001 == 0 else { throw failure("Absolute fragment offsets are unsupported") }
        guard try u32(data, at: tfhd.payload + 4) == trackID else { throw failure("Unexpected MP4 fragment track") }
        var cursor = tfhd.payload + 8
        if tfhdFlags & 0x000001 != 0 { cursor += 8 }
        var sampleDuration = defaultSampleDuration
        if tfhdFlags & 0x000002 != 0 { cursor += 4 }
        if tfhdFlags & 0x000008 != 0 { sampleDuration = try u32(data, at: cursor); cursor += 4 }
        guard cursor <= tfhd.end else { throw failure("Truncated fragment defaults") }
        let tfdtVersion = data[tfdt.payload]
        guard tfdt.payload + (tfdtVersion == 1 ? 12 : 8) <= tfdt.end else { throw failure("Truncated fragment timestamp") }
        let startTicks: UInt64 = tfdtVersion == 1 ? try u64(data, at: tfdt.payload + 4) : UInt64(try u32(data, at: tfdt.payload + 4))
        var total: UInt64 = 0
        var totalSamples: UInt64 = 0
        for trun in truns {
            guard trun.payload + 8 <= trun.end else { throw failure("Truncated MP4 sample table") }
            let trunVersion = data[trun.payload]
            let flags = try u24(data, at: trun.payload + 1)
            var p = trun.payload + 8
            let count = try u32(data, at: trun.payload + 4)
            guard count > 0, count <= 100_000, totalSamples + UInt64(count) <= 100_000 else { throw failure("Invalid MP4 sample count") }
            totalSamples += UInt64(count)
            if flags & 0x000001 != 0 { p += 4 }
            if flags & 0x000004 != 0 { p += 4 }
            for _ in 0..<count {
                let duration: UInt32
                if flags & 0x000100 != 0 { duration = try u32(data, at: p); p += 4 }
                else if let sampleDuration { duration = sampleDuration }
                else { throw failure("MP4 sample duration unavailable") }
                guard duration > 0 else { throw failure("Invalid MP4 sample duration") }
                let sum = total.addingReportingOverflow(UInt64(duration))
                guard !sum.overflow else { throw failure("Invalid MP4 fragment duration") }
                total = sum.partialValue
                if flags & 0x000200 != 0 { p += 4 }
                if flags & 0x000400 != 0 { p += 4 }
                if flags & 0x000800 != 0 { p += 4 }
                guard p <= trun.end else { throw failure("Truncated MP4 sample table") }
            }
            guard trunVersion <= 1 else { throw failure("Unsupported MP4 timing version") }
        }
        if tfdtVersion > 1 { throw failure("Unsupported MP4 timing version") }
        if let lastEnd, startTicks != lastEnd { throw failure("MP4 fragment timestamp discontinuity") }
        let end = startTicks.addingReportingOverflow(total)
        guard !end.overflow, total > 0 else { throw failure("Invalid MP4 fragment duration") }
        sequence = seq; lastEnd = end.partialValue
        return Fragment(data: data, start: Double(startTicks) / Double(timescale), duration: Double(total) / Double(timescale))
    }

    private func inspectEC3Entry(_ data: Data, entry: Box) throws -> Bool {
        guard entry.end - entry.payload >= 28 else { throw failure("Truncated E-AC-3 sample entry") }
        let version = try u16(data, at: entry.payload + 8)
        guard version == 0 else { throw failure("Unsupported E-AC-3 sample entry version") }
        let children = try boxes(in: data, from: entry.payload + 28, to: entry.end, allowPartial: false)
        guard !children.contains(where: { ["sinf", "senc", "saiz", "saio"].contains($0.type) }) else { throw failure("Protected audio is unsupported") }
        guard let dec3 = children.first(where: { $0.type == "dec3" }) else { throw failure("E-AC-3 configuration missing") }
        return try jocSignaled(data, from: dec3.payload, to: dec3.end)
    }

    private func jocSignaled(_ data: Data, from start: Int, to end: Int) throws -> Bool {
        var bit = start * 8
        func read(_ count: Int) throws -> UInt32 {
            guard count >= 0, bit + count <= end * 8 else { throw failure("Truncated E-AC-3 configuration") }
            var value: UInt32 = 0
            for _ in 0..<count { value = (value << 1) | UInt32((data[bit >> 3] >> (7 - (bit & 7))) & 1); bit += 1 }
            return value
        }
        _ = try read(13)
        let count = Int(try read(3)) + 1
        for _ in 0..<count {
            _ = try read(2 + 5 + 1 + 1 + 3 + 3 + 1 + 3)
            let dependents = Int(try read(4))
            _ = try read(dependents > 0 ? 9 : 1)
        }
        guard end * 8 - bit >= 8 else { return false }
        _ = try read(7)
        let joc = try read(1) == 1
        if joc { _ = try read(8) }
        return joc
    }

    private func boxes(in data: Data, from start: Int, to limit: Int, allowPartial: Bool) throws -> [Box] {
        var result: [Box] = [], p = start
        while p < limit {
            if limit - p < 8 { if allowPartial { break }; throw failure("Truncated MP4 box") }
            let size32 = try u32(data, at: p), type = try fourCC(data, at: p + 4)
            var header = 8, size = UInt64(size32)
            if size32 == 1 {
                if limit - p < 16 { if allowPartial { break }; throw failure("Truncated MP4 extended box header") }
                size = try u64(data, at: p + 8); header = 16
            } else if size32 == 0 { throw failure("Open-ended MP4 boxes are unsupported") }
            guard size >= UInt64(header), p <= limit - header else { throw failure("Invalid MP4 box size") }
            guard size <= UInt64(limit - p) else {
                if allowPartial { break }
                throw failure("Truncated MP4 box")
            }
            let end = p + Int(size)
            result.append(Box(type: type, start: p, payload: p + header, end: end)); p = end
        }
        return result
    }

    private func u16(_ data: Data, at p: Int) throws -> UInt16 { guard p >= 0, p + 2 <= data.count else { throw failure("Truncated MP4 metadata") }; return UInt16(data[p]) << 8 | UInt16(data[p + 1]) }
    private func u24(_ data: Data, at p: Int) throws -> UInt32 { guard p >= 0, p + 3 <= data.count else { throw failure("Truncated MP4 metadata") }; return UInt32(data[p]) << 16 | UInt32(data[p + 1]) << 8 | UInt32(data[p + 2]) }
    private func u32(_ data: Data, at p: Int) throws -> UInt32 { guard p >= 0, p + 4 <= data.count else { throw failure("Truncated MP4 metadata") }; return UInt32(data[p]) << 24 | UInt32(data[p + 1]) << 16 | UInt32(data[p + 2]) << 8 | UInt32(data[p + 3]) }
    private func u64(_ data: Data, at p: Int) throws -> UInt64 { UInt64(try u32(data, at: p)) << 32 | UInt64(try u32(data, at: p + 4)) }
    private func fourCC(_ data: Data, at p: Int) throws -> String { guard p >= 0, p + 4 <= data.count else { throw failure("Truncated MP4 metadata") }; return String(bytes: data[p..<(p + 4)], encoding: .ascii) ?? "" }
    private func failure(_ message: String) -> NSError { NSError(domain: "NetflixDev.NativeAudioBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
