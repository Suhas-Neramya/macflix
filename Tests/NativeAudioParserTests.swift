import Foundation

@main
enum NativeAudioParserTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let initialization = try Data(contentsOf: root.appendingPathComponent("Tests/fixtures/apple-atmos-init.mp4"))
        let fragment = try Data(contentsOf: root.appendingPathComponent("Tests/fixtures/apple-first-fragment.m4s"))
        var parser = MP4AudioStream()
        var events: [MP4AudioStream.Event] = []
        for chunk in initialization.chunks(of: 17) { events += try parser.append(chunk) }
        guard events.contains(where: { if case .initialization = $0 { true } else { false } }) else { throw TestFailure("split initialization was not reassembled") }
        events = []
        for chunk in fragment.chunks(of: 4093) { events += try parser.append(chunk) }
        guard let parsed = events.compactMap({ event -> MP4AudioStream.Fragment? in if case .fragment(let fragment) = event { fragment } else { nil } }).first else {
            throw TestFailure("split fragment was not reassembled")
        }
        try expect(abs(parsed.start - 10) < 0.000_001, "fixture tfdt should map to 10 seconds")
        try expect(abs(parsed.duration - 5.984) < 0.000_001, "fixture trun duration should be 5.984 seconds")
        try expect(parsed.data == fragment, "fragment bytes must remain unchanged")

        var encrypted = initialization
        guard let entry = encrypted.range(of: Data("ec-3".utf8)) else { throw TestFailure("fixture has no E-AC-3 entry") }
        encrypted.replaceSubrange(entry, with: Data("enca".utf8))
        var protectedParser = MP4AudioStream()
        do { _ = try protectedParser.append(encrypted); throw TestFailure("protected entry was accepted") }
        catch is TestFailure { throw TestFailure("protected entry was accepted") }
        catch { }

        var truncatedParser = MP4AudioStream()
        do { _ = try truncatedParser.append(Data([0, 0, 0, 4, 0x6d, 0x6f, 0x6f, 0x76])); throw TestFailure("invalid MP4 box was accepted") }
        catch is TestFailure { throw TestFailure("invalid MP4 box was accepted") }
        catch { }
        print("Passed: split init and fragment reassembly, clear JOC validation, tfdt/trun timing, byte preservation, and malformed/protected rejection.")
    }

    private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message) } }
}

private struct TestFailure: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }

private extension Data {
    func chunks(of size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { subdata(in: $0..<Swift.min($0 + size, count)) }
    }
}
