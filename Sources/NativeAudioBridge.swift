import Foundation
import AVFoundation
import Network

final class NativeAudioBridge {
    private struct Segment {
        let sequence: Int
        let start: Double
        let duration: Double
        let data: Data
        var end: Double { start + duration }
    }

    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var token = UUID().uuidString
    private var files: [String: Data] = [:]
    private var segments: [Segment] = []
    private var totalBytes = 0
    private var targetDuration = 0
    private var session = -1
    private var player: AVPlayer?
    private var parser = MP4AudioStream()
    private var anchor: Double?
    private var seeking = false
    private var desiredPaused = true
    private var lastHeartbeat = Date.distantPast
    private var lastWebTime = 0.0
    private var desiredMuted = true
    private var handshakeAudible = false
    private var listenerFailed = false
    private var watchdog: Timer?
    private(set) var servedSegments = Set<String>()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { DispatchQueue.main.async { try? self.preparePlayer() } }
            if case .failed = state { self.listenerFailed = true; self.player?.isMuted = true; self.player?.pause() }
        }
        listener.start(queue: .main)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastHeartbeat) > 2 else { return }
            self.player?.isMuted = true; self.player?.pause(); self.handshakeAudible = false
        }
    }

    deinit { watchdog?.invalidate(); listener.cancel(); connections.values.forEach { $0.cancel() } }

    func stop() { reset() }

    func handle(_ body: [String: Any]) throws -> [String: Any] {
        guard let action = body["action"] as? String, let id = body["session"] as? Int else { throw failure("Invalid bridge message") }
        if action == "begin" {
            if listenerFailed { throw failure("Native audio listener failed") }
            guard id > session else { throw failure("Stale session") }
            reset(); session = id
            return snapshot(state: "collecting")
        }
        guard id == session else { throw failure("Stale session") }
        if listenerFailed && action != "stop" { throw failure("Native audio listener failed") }
        switch action {
        case "stop": reset(); return snapshot(state: "stopped")
        case "append":
            guard let encoded = body["data"] as? String, encoded.utf8.count <= 11_184_812,
                  let data = Data(base64Encoded: encoded), data.count <= 8 * 1024 * 1024,
                  totalBytes + data.count <= 64 * 1024 * 1024 else { throw failure("Invalid or oversized MP4 append") }
            let events = try parser.append(data)
            for event in events {
                switch event {
                case .initialization(let initData): files["init.mp4"] = initData; totalBytes += initData.count
                case .fragment(let fragment):
                    let segment = Segment(sequence: segments.last.map { $0.sequence + 1 } ?? 0, start: fragment.start, duration: fragment.duration, data: fragment.data)
                    guard segment.duration <= 30 else { throw failure("MP4 fragment duration exceeds limit") }
                    let duration = Int(ceil(segment.duration))
                    guard player == nil || duration <= targetDuration else { throw failure("Fragment duration changed beyond HLS target") }
                    targetDuration = max(targetDuration, duration)
                    segments.append(segment); totalBytes += fragment.data.count
                    files[segmentName(segment.sequence)] = fragment.data
                }
            }
            guard totalBytes <= 64 * 1024 * 1024 else { throw failure("Retained MP4 stream limit exceeded") }
            try preparePlayer()
            return snapshot(state: player == nil ? "collecting" : "preparing")
        case "sync":
            guard let time = body["time"] as? Double, time.isFinite, time >= 0, time < 1_000_000,
                  let paused = body["paused"] as? Bool, let isSeeking = body["seeking"] as? Bool,
                  let rate = body["rate"] as? Double, rate.isFinite,
                  let volume = body["volume"] as? Double, volume.isFinite, (0...1).contains(volume),
                  let muted = body["muted"] as? Bool, let audible = body["audible"] as? Bool else { throw failure("Invalid playback clock") }
            lastHeartbeat = Date(); lastWebTime = time; desiredPaused = paused; desiredMuted = muted
            handshakeAudible = audible && rate == 1 && !isSeeking
            guard let player, let item = player.currentItem else {
                self.player?.isMuted = true
                return snapshot(state: "collecting", requestedTime: time, requestedRate: rate, requestedSeeking: isSeeking)
            }
            if item.status == .failed { player.isMuted = true; throw failure("Native audio could not decode the sample") }
            player.volume = Float(volume)
            guard rate == 1, !isSeeking else {
                player.isMuted = true; player.pause()
                return snapshot(state: item.status == .readyToPlay ? "ready" : "preparing", requestedTime: time, requestedRate: rate, requestedSeeking: isSeeking)
            }
            guard item.status == .readyToPlay else {
                player.isMuted = true; return snapshot(state: "preparing", requestedTime: time, requestedRate: rate, requestedSeeking: isSeeking)
            }
            if anchor == nil, let first = segments.first,
               let range = item.seekableTimeRanges.first?.timeRangeValue, range.start.seconds.isFinite {
                anchor = first.start - range.start.seconds
            }
            guard let offset = anchor, seekable(item, contains: time - offset) else {
                player.isMuted = true; player.pause()
                return snapshot(state: "preparing", requestedTime: time, requestedRate: rate, requestedSeeking: isSeeking)
            }
            let native = player.currentTime().seconds
            let mapped = native + offset
            player.isMuted = muted || !audible || paused
            // Anchor native playback to the same host clock instead of chasing the web clock with asynchronous seeks.
            if !mapped.isFinite || abs(mapped - time) > 0.10 || (paused ? player.rate != 0 : player.rate == 0) {
                player.setRate(paused ? 0 : 1,
                               time: CMTime(seconds: time - offset, preferredTimescale: 48_000),
                               atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            prune(behind: time)
            return snapshot(state: "preparing", requestedTime: time, requestedRate: rate, requestedSeeking: isSeeking)
        case "status": return snapshot(state: player == nil ? "collecting" : "preparing")
        default: throw failure("Unknown bridge action")
        }
    }

    private func reset() {
        player?.isMuted = true; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        seeking = false; token = UUID().uuidString; files.removeAll(); segments.removeAll(); totalBytes = 0; targetDuration = 0
        parser = MP4AudioStream(); anchor = nil; lastWebTime = 0; desiredMuted = true; handshakeAudible = false
        servedSegments.removeAll(); lastHeartbeat = .distantPast
        connections.values.forEach { $0.cancel() }; connections.removeAll()
    }

    private func snapshot(state fallbackState: String, requestedTime: Double? = nil, requestedRate: Double = 1, requestedSeeking: Bool = false) -> [String: Any] {
        guard let player, let item = player.currentItem else {
            return ["state": fallbackState, "nativeTime": 0.0, "driftSeconds": 0.0, "seeking": false, "rate": requestedRate, "segments": segments.count, "bytes": totalBytes, "audible": false]
        }
        let native = player.currentTime().seconds
        let mapped = native.isFinite ? native + (anchor ?? 0) : 0
        let time = mapped.isFinite ? mapped : 0
        let webTime = requestedTime ?? lastWebTime
        let drift = time - webTime
        let hasData = item.loadedTimeRanges.contains { range in
            CMTimeRangeContainsTime(range.timeRangeValue, time: player.currentTime())
        }
        let isReady = hasData && (desiredPaused || player.timeControlStatus == .playing) && item.status == .readyToPlay && anchor != nil && seekable(item, contains: webTime - (anchor ?? 0)) && abs(drift) < 0.15 && !seeking && !requestedSeeking
        let audible = isReady && !player.isMuted && !desiredMuted && handshakeAudible && Date().timeIntervalSince(lastHeartbeat) <= 2 && !desiredPaused && requestedRate == 1
        return ["state": isReady ? "ready" : fallbackState, "nativeTime": time, "driftSeconds": drift.isFinite ? drift : 0, "seeking": seeking || requestedSeeking, "rate": Double(player.rate), "segments": segments.count, "bytes": totalBytes, "audible": audible, "servedSegments": servedSegments.count, "nativeSeekable": item.seekableTimeRanges.map { [$0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds] }, "loaded": item.loadedTimeRanges.map { [$0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds] }]
    }

    private func preparePlayer() throws {
        guard player == nil, files["init.mp4"] != nil, segments.count >= 3, let port = listener.port else { return }
        let root = "http://127.0.0.1:\(port.rawValue)/\(token)/"
        let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"atmos\",NAME=\"English\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"16/JOC\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\"ec-3\",AUDIO=\"atmos\"\naudio.m3u8\n"
        files["master.m3u8"] = Data(master.utf8)
        let item = AVPlayerItem(url: URL(string: root + "master.m3u8")!)
        item.allowedAudioSpatializationFormats = .multichannel
        player = AVPlayer(playerItem: item); player?.automaticallyWaitsToMinimizeStalling = false; player?.isMuted = true
    }

    private func playlist() -> Data {
        let duration = max(1, targetDuration)
        let first = segments.first?.sequence ?? 0
        var value = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n#EXT-X-TARGETDURATION:\(duration)\n#EXT-X-MEDIA-SEQUENCE:\(first)\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for segment in segments {
            let duration = String(format: "%.6f", segment.duration)
            value += "#EXTINF:\(duration),\n\(segmentName(segment.sequence))\n"
        }
        return Data(value.utf8)
    }

    private func segmentName(_ sequence: Int) -> String { "segment\(sequence).m4s" }

    private func seekable(_ item: AVPlayerItem, contains time: Double) -> Bool {
        guard time.isFinite else { return false }
        return item.seekableTimeRanges.contains { value in
            let range = value.timeRangeValue
            return range.start.seconds <= time && time <= CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
        }
    }

    private func prune(behind time: Double) {
        while segments.count > 3, let first = segments.first, first.end < time - 15 {
            segments.removeFirst(); totalBytes -= first.data.count; files.removeValue(forKey: segmentName(first.sequence))
        }
    }

    static func failureCategory(for error: Error) -> String {
        let failure = error as NSError
        guard failure.domain == "NetflixDev.NativeAudioBridge" else { return "native-error" }
        let message = failure.localizedDescription.lowercased()
        if message.contains("protected") || message.contains("encrypted") || message.contains("pssh") { return "protected-audio" }
        if message.contains("joc") || message.contains("codec") { return "unsupported-audio" }
        if message.contains("decode") { return "decode-error" }
        if message.contains("listener") { return "listener-failed" }
        if message.contains("stale session") { return "stale-session" }
        if message.contains("invalid bridge message") || message.contains("invalid playback clock") || message.contains("unknown bridge action") { return "invalid-message" }
        if message.contains("mp4") { return "parser-error" }
        return "native-error"
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "NetflixDev.NativeAudioBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in connection?.cancel(); self?.connections.removeValue(forKey: id) }
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated; request.append(data ?? Data())
            guard request.count <= 8192, error == nil else { self.finish(connection, id: id); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { self.respond(connection, id: id, request: request) }
            else if complete { self.finish(connection, id: id) }
            else { self.receive(connection, id: id, accumulated: request) }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { finish(connection, id: id); return }
        let lines = text.components(separatedBy: "\r\n"), fields = lines[0].split(separator: " ")
        let prefix = "/\(token)/"
        guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD", fields[1].hasPrefix(prefix) else {
            send(connection, id: id, status: "404 Not Found", type: "text/plain", data: Data()); return
        }
        let name = String(fields[1].dropFirst(prefix.count))
        let resource = name == "audio.m3u8" ? playlist() : files[name]
        guard var body = resource else { send(connection, id: id, status: "404 Not Found", type: "text/plain", data: Data()); return }
        if name.hasSuffix(".m4s") { servedSegments.insert(name) }
        var code = "200 OK", extra = ""
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = rangeLine.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let bounds = value.hasPrefix("bytes=") ? value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
            guard bounds.count == 2, let lower = Int(bounds[0]), lower >= 0, lower < body.count,
                  let upper = bounds[1].isEmpty ? body.count - 1 : Int(bounds[1]), upper >= lower, upper < body.count else {
                send(connection, id: id, status: "416 Range Not Satisfiable", type: "text/plain", data: Data()); return
            }
            body = body.subdata(in: lower..<(upper + 1)); code = "206 Partial Content"
            extra = "Content-Range: bytes \(lower)-\(upper)/\(resource!.count)\r\n"
        }
        send(connection, id: id, status: code, type: name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "audio/mp4", data: body, extra: extra, head: fields[0] == "HEAD")
    }

    private func send(_ connection: NWConnection, id: UUID, status: String, type: String, data: Data, extra: String = "", head: Bool = false) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n".utf8)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(connection, id: id) })
    }
    private func finish(_ connection: NWConnection, id: UUID) { connection.cancel(); connections.removeValue(forKey: id) }
}
