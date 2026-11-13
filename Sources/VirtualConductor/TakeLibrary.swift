import Foundation
import CryptoKit
import ConductorCore

struct SavedTake: Codable, Identifiable, Sendable {
    var version = 1
    let id: UUID
    let created: Date
    let score: String
    let sampleRate: Double
    let sampleCount: Int
    let range: PassageRange
    var trackIndex: Int
    var beats: [BeatTime]
    var origins: [BeatOrigin]
    var approved: Bool
    var manualStart: Double
    var manualEnd: Double
    var title: String { "\(created.formatted(date: .abbreviated, time: .standard)) · m. \(Int(range.start / 4) + 1)–\(Int(ceil(range.end / 4)))" }
}

/// Immutable PCM plus atomically replaced metadata. Never deletes owner takes.
/// Instances have no mutable state; callers serialize mutations for a given take.
struct TakeLibrary: Sendable {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VirtualConductor/Takes/v1", isDirectory: true)) { self.root = root }
    private func directory(_ score: String) -> URL {
        let key = SHA256.hash(data: Data(score.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }
    func list(score: String) throws -> (takes: [SavedTake], unreadable: Int) {
        let dir = directory(score)
        guard FileManager.default.fileExists(atPath: dir.path) else { return ([], 0) }
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var takes: [SavedTake] = [], unreadable = 0
        for url in urls {
            do {
                let item = try JSONDecoder().decode(SavedTake.self, from: Data(contentsOf: url))
                guard item.version == 1, item.score == score, url.lastPathComponent == item.id.uuidString + ".json" else { throw MusicalError("Unsupported saved take.") }
                takes.append(item)
            } catch { unreadable += 1 }
        }
        return (takes.sorted { $0.created > $1.created }, unreadable)
    }
    func save(_ item: SavedTake, samples: [Float]? = nil) throws {
        let dir = directory(item.score)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent(item.id.uuidString + ".pcm")
        if !FileManager.default.fileExists(atPath: audio.path) {
            guard let samples, samples.count == item.sampleCount, samples.allSatisfy({ $0.isFinite }) else { throw MusicalError("The take's audio is not available to save.") }
            let data = samples.withUnsafeBytes { Data($0) }
            try data.write(to: audio, options: .atomic)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(item).write(to: dir.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
    }
    func load(_ item: SavedTake) throws -> RecordedTake {
        guard item.version == 1, item.sampleRate.isFinite, (1...384000).contains(item.sampleRate),
              item.sampleCount > 0, Double(item.sampleCount) / item.sampleRate <= 120.1,
              item.range.start.isFinite, item.range.end.isFinite, item.range.end > item.range.start else { throw MusicalError("This saved take has invalid metadata.") }
        let data = try Data(contentsOf: directory(item.score).appendingPathComponent(item.id.uuidString + ".pcm"))
        guard data.count / 4 == item.sampleCount, data.count % 4 == 0 else { throw MusicalError("This saved take's audio is incomplete. The original files have been retained.") }
        let samples = data.withUnsafeBytes { bytes in (0..<item.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        guard samples.allSatisfy({ $0.isFinite }) else { throw MusicalError("This saved take contains invalid audio.") }
        return RecordedTake(samples: samples, sampleRate: item.sampleRate, range: item.range)
    }
}
