import XCTest
import ConductorCore
@testable import VirtualConductor

final class SettingsBridgeTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)
    private let otherFingerprint = String(repeating: "b", count: 64)
    private let passage = CadenzaPassage(startMeasure: 1, startBeat: 2, returnMeasure: 2, returnBeat: 1)

    private func withStore(_ body: (CadenzaSettings, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/cadenzas-v1.json")
        try body(CadenzaSettings(fileURL: file), file)
    }
    private func midi() throws -> MIDIFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fractional-tempo", withExtension: "mid", subdirectory: "Fixtures"))
        return try MIDIFile(data: Data(contentsOf: url))
    }

    func testSettingsPersistPerExactFingerprintAndEmptySaveRemovesPassages() throws {
        try withStore { store, file in
            XCTAssertEqual(try store.load(fingerprint: fingerprint), [])
            try store.save([passage], fingerprint: fingerprint)
            let reopened = CadenzaSettings(fileURL: file)
            XCTAssertEqual(try reopened.load(fingerprint: fingerprint), [passage])
            XCTAssertEqual(try reopened.load(fingerprint: otherFingerprint), [])
            try reopened.save([passage], fingerprint: otherFingerprint)
            try reopened.save([], fingerprint: fingerprint)
            XCTAssertEqual(try store.load(fingerprint: fingerprint), [])
            XCTAssertEqual(try store.load(fingerprint: otherFingerprint), [passage])
        }
    }

    func testBrowserBridgeImportsOnlyMatchingValidatedScoreAndPreservesPriorSettingsOnError() throws {
        let score = try midi()
        try withStore { store, file in
            let bridge = try store.exportBridge([passage], fingerprint: fingerprint)
            XCTAssertEqual(try store.importBridge(data: bridge, fingerprint: fingerprint, midi: score, audioDuration: 10), [passage])
            let saved = try Data(contentsOf: file)
            XCTAssertThrowsError(try store.importBridge(data: bridge, fingerprint: otherFingerprint, midi: score, audioDuration: 10))
            XCTAssertThrowsError(try store.importBridge(data: bridge, fingerprint: fingerprint, midi: score, audioDuration: 0.5))
            var document = try JSONSerialization.jsonObject(with: bridge) as! [String: Any]
            document["schemaVersion"] = 2
            XCTAssertThrowsError(try store.importBridge(data: JSONSerialization.data(withJSONObject: document), fingerprint: fingerprint, midi: score, audioDuration: 10))
            document["schemaVersion"] = 1
            document["passages"] = [["startMeasure": 1, "startBeat": 1, "returnMeasure": 999, "returnBeat": 1]]
            XCTAssertThrowsError(try store.importBridge(data: JSONSerialization.data(withJSONObject: document), fingerprint: fingerprint, midi: score, audioDuration: 10))
            XCTAssertEqual(try Data(contentsOf: file), saved)
            XCTAssertEqual(try store.load(fingerprint: fingerprint), [passage])
        }
    }

    func testCorruptStoredDataAndInvalidSavesNeverOverwriteExistingFile() throws {
        try withStore { store, file in
            try store.save([passage], fingerprint: fingerprint)
            let saved = try Data(contentsOf: file)
            XCTAssertThrowsError(try store.save([passage, passage], fingerprint: fingerprint))
            XCTAssertThrowsError(try store.save([], fingerprint: "wrong"))
            XCTAssertEqual(try Data(contentsOf: file), saved)
            try Data("corrupt".utf8).write(to: file)
            XCTAssertThrowsError(try store.load(fingerprint: fingerprint))
            XCTAssertThrowsError(try store.save([], fingerprint: fingerprint))
            XCTAssertEqual(try Data(contentsOf: file), Data("corrupt".utf8))
        }
    }
}
