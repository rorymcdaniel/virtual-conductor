import Foundation
import ConductorCore

/// This store belongs to Virtual Conductor; browser storage is imported only
/// through an explicit export file for the currently loaded MIDI fingerprint.
final class CadenzaSettings {
    private struct Store: Codable {
        var schemaVersion = 1
        var passagesByFingerprint: [String: [CadenzaPassage]] = [:]
    }
    private struct Bridge: Codable {
        let schemaVersion: Int
        let midiSHA256: String
        let passages: [CadenzaPassage]
    }
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VirtualConductor", isDirectory: true)
            .appendingPathComponent("cadenzas-v1.json")
    }

    func load(fingerprint: String) throws -> [CadenzaPassage] {
        try Self.validateFingerprint(fingerprint)
        return try lock.withLock { try readStore().passagesByFingerprint[fingerprint] ?? [] }
    }

    func save(_ passages: [CadenzaPassage], fingerprint: String) throws {
        try Self.validateFingerprint(fingerprint)
        try Self.validatePassages(passages)
        try lock.withLock {
            var store = try readStore()
            store.passagesByFingerprint[fingerprint] = passages
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store).write(to: fileURL, options: .atomic)
        }
    }

    /// Validate the complete incoming document and musical bounds before any write.
    @discardableResult
    func importBridge(data: Data, fingerprint: String, midi: MIDIFile, audioDuration: Double) throws -> [CadenzaPassage] {
        try Self.validateFingerprint(fingerprint)
        let document: Bridge
        do { document = try JSONDecoder().decode(Bridge.self, from: data) }
        catch { throw MusicalError("Choose a valid Virtual Conductor cadenza settings export.") }
        guard document.schemaVersion == 1 else { throw MusicalError("This cadenza settings export uses an unsupported schema version.") }
        try Self.validateFingerprint(document.midiSHA256)
        guard document.midiSHA256 == fingerprint else { throw MusicalError("These cadenza settings belong to a different MIDI export.") }
        let compiled = try compileCadenzas(document.passages, midi: midi, audioDuration: audioDuration)
        let passages = compiled.map(\.passage)
        try save(passages, fingerprint: fingerprint)
        return passages
    }

    func exportBridge(_ passages: [CadenzaPassage], fingerprint: String) throws -> Data {
        try Self.validateFingerprint(fingerprint)
        try Self.validatePassages(passages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Bridge(schemaVersion: 1, midiSHA256: fingerprint, passages: passages))
    }

    private func readStore() throws -> Store {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Store() }
        let store: Store
        do { store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: fileURL)) }
        catch { throw MusicalError("Saved cadenza settings could not be read: \(error.localizedDescription)") }
        guard store.schemaVersion == 1 else { throw MusicalError("Saved cadenza settings use an unsupported schema version.") }
        for (fingerprint, passages) in store.passagesByFingerprint {
            try Self.validateFingerprint(fingerprint)
            try Self.validatePassages(passages)
        }
        return store
    }

    private static func validateFingerprint(_ fingerprint: String) throws {
        guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MusicalError("Cadenza settings require a SHA-256 fingerprint of the exact MIDI export.")
        }
    }

    private static func validatePassages(_ passages: [CadenzaPassage]) throws {
        var ranges: [(Double, Double)] = []
        for (index, passage) in passages.enumerated() {
            guard passage.startMeasure >= 1, passage.returnMeasure >= 1,
                  (1...4).contains(passage.startBeat), (1...4).contains(passage.returnBeat) else {
                throw MusicalError("Passage \(index + 1): choose a whole measure number and a whole beat from 1 to 4.")
            }
            let start = (Double(passage.startMeasure) - 1) * 4 + Double(passage.startBeat) - 1
            let end = (Double(passage.returnMeasure) - 1) * 4 + Double(passage.returnBeat) - 1
            guard end > start else { throw MusicalError("Passage \(index + 1): return must be after the start.") }
            ranges.append((start, end))
        }
        ranges.sort { $0.0 < $1.0 }
        for index in ranges.indices.dropFirst() {
            guard ranges[index].0 > ranges[index - 1].1 else { throw MusicalError("Cadenza passages cannot overlap or share a return/start beat.") }
        }
    }
}
