import Foundation
import XCTest
import ConductorCore

final class MusicXMLTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "musicxml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testSingleStaffHasCompleteMeasuresAndQuarterPositions() throws {
        let score = try MusicXMLScore(data: fixture("musicxml-single-staff"))
        XCTAssertEqual(score.staves.count, 1)
        XCTAssertEqual(score.staves[0].id, MusicXMLStaffID(partID: "P1", staffNumber: 1))
        XCTAssertEqual(score.staves[0].displayName, " Solo Flute ")
        XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(score.measures.map(\.startQuarter), [0, 4, 8])
        XCTAssertEqual(score.measures.map(\.endQuarter), [4, 8, 12])
        XCTAssertEqual(score.endQuarter, 12)
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.startQuarter), [0.5, 1, 9])
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.endQuarter), [1, 4, 12])
    }

    func testMultiStaffPartsKeepIndependentIdentitiesAndOverlappingVoices() throws {
        let score = try MusicXMLScore(data: fixture("musicxml-multi-staff"))
        XCTAssertEqual(score.staves.map(\.id), [
            MusicXMLStaffID(partID: "Piano", staffNumber: 1),
            MusicXMLStaffID(partID: "Piano", staffNumber: 2),
            MusicXMLStaffID(partID: "Other", staffNumber: 1)
        ])
        guard score.staves.count == 3 else { return }
        XCTAssertEqual(score.staves.map(\.displayName), ["Piano (staff 1)", "Piano (staff 2)", "Piano"])
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.startQuarter), [0, 0, 1])
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.endQuarter), [4, 4, 4])
        XCTAssertEqual(score.staves[1].soundingIntervals.map(\.startQuarter), [0.5])
        XCTAssertEqual(score.staves[1].soundingIntervals.map(\.endQuarter), [4])
        XCTAssertEqual(score.staves[2].soundingIntervals.map(\.startQuarter), [4])
        XCTAssertEqual(score.endQuarter, 8)
    }

    func testTiesRemainSoundingAcrossMeasuresIndependentlyForEachVoice() throws {
        let score = try MusicXMLScore(data: fixture("musicxml-ties"))
        let intervals = score.staves[0].soundingIntervals
        XCTAssertEqual(intervals.count, 2)
        guard intervals.count == 2 else { return }
        XCTAssertEqual(intervals[0].startQuarter, 0)
        XCTAssertEqual(intervals[0].endQuarter, 9)
        XCTAssertEqual(intervals[1].startQuarter, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(intervals[1].endQuarter, 5)
        for quarter in [0.0, 3.99, 4, 5, 7.99, 8, 8.99] {
            XCTAssertTrue(intervals.contains { $0.startQuarter <= quarter && quarter < $0.endQuarter })
        }
        XCTAssertFalse(intervals.contains { $0.startQuarter <= 9 && 9 < $0.endQuarter })
        XCTAssertEqual(score.endQuarter, 12)
    }

    func testPickupsAreExplicitlyUnsupportedWithAndWithoutImplicitMarker() throws {
        let xml = String(decoding: try fixture("musicxml-pickup"), as: UTF8.self)
        for input in [xml, xml.replacingOccurrences(of: " implicit=\"yes\"", with: "")] {
            XCTAssertThrowsError(try MusicXMLScore(data: Data(input.utf8))) {
                XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.pickup))
            }
        }
    }

    func testMeterMustStayFourFourIncludingStaffSpecificTimeSignatures() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        let common = "<time><beats>4</beats><beat-type>4</beat-type></time>"
        for meter in ["<time><beats>3</beats><beat-type>4</beat-type></time>", "<time><beats>2</beats><beat-type>2</beat-type></time>", "<time><senza-misura/></time>"] {
            XCTAssertThrowsError(try MusicXMLScore(data: Data(xml.replacingOccurrences(of: common, with: meter).utf8))) {
                XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.nonFourFourMeter))
            }
        }
        let changed = xml.replacingOccurrences(of: "<divisions>8</divisions>", with: "<divisions>8</divisions><time><beats>3</beats><beat-type>4</beat-type></time>")
        XCTAssertThrowsError(try MusicXMLScore(data: Data(changed.utf8))) {
            XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.changingMeter))
        }
        let repeated = xml.replacingOccurrences(of: "<divisions>8</divisions>", with: "<divisions>8</divisions>" + common)
        XCTAssertEqual(try MusicXMLScore(data: Data(repeated.utf8)).endQuarter, 12)
        let polymeter = xml.replacingOccurrences(of: common, with: common + "<time number=\"2\"><beats>3</beats><beat-type>4</beat-type></time>")
        XCTAssertThrowsError(try MusicXMLScore(data: Data(polymeter.utf8))) {
            XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.nonFourFourMeter))
        }
    }

    func testRepeatsAndJumpsReturnExplicitReasonsWithoutExpansion() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        let directions = [
            "<barline><repeat direction=\"backward\"/></barline>",
            "<barline><repeat direction=\"forward\"/></barline>",
            "<barline><ending number=\"1\" type=\"start\"/></barline>",
            "<direction><sound dacapo=\"yes\"/></direction>",
            "<direction><sound dalsegno=\"segno\"/></direction>",
            "<direction><sound tocoda=\"coda\"/></direction>",
            "<direction><sound fine=\"yes\"/></direction>",
            "<direction><direction-type><segno/></direction-type></direction>",
            "<direction><direction-type><coda/></direction-type></direction>",
            "<direction><direction-type><words>D.C. al Fine</words></direction-type></direction>",
            "<attributes><measure-style><measure-repeat type=\"start\">1</measure-repeat></measure-style></attributes>",
            "<attributes><measure-style><beat-repeat type=\"start\"/></measure-style></attributes>"
        ]
        for direction in directions {
            let input = xml.replacingOccurrences(of: "<measure number=\"2\">", with: "<measure number=\"2\">" + direction)
            XCTAssertThrowsError(try MusicXMLScore(data: Data(input.utf8)), direction) {
                XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.repeatsOrJumps), direction)
            }
        }
    }

    func testUnestablishedPlaybackStructuresAreExplicitlyUnsupported() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        let inputs = [
            xml.replacingOccurrences(of: "score-partwise", with: "score-timewise"),
            xml.replacingOccurrences(of: "<time><beats>4</beats><beat-type>4</beat-type></time>", with: ""),
            xml.replacingOccurrences(of: "<measure number=\"2\">", with: "<measure number=\"2\" non-controlling=\"yes\">"),
            xml.replacingOccurrences(of: "<note><pitch>", with: "<note><grace/><pitch>"),
            xml.replacingOccurrences(of: "<duration>16</duration>", with: "<duration>8</duration>"),
            xml.replacingOccurrences(of: "<duration>16</duration>", with: "<duration>32</duration>"),
            xml.replacingOccurrences(of: "<note><pitch>", with: "<note attack=\"1\"><pitch>"),
            xml.replacingOccurrences(of: "<type>eighth</type>", with: "<type>eighth</type><notations><ornaments><tremolo type=\"start\">3</tremolo></ornaments></notations>")
        ]
        for input in inputs {
            XCTAssertThrowsError(try MusicXMLScore(data: Data(input.utf8))) {
                guard case .unsupportedCue(.unestablishedPlayback(let detail)) = $0 as? MusicXMLReadError else {
                    return XCTFail("Expected explicit unsupported mapping, got \($0)")
                }
                XCTAssertFalse(detail.isEmpty)
            }
        }
        let multi = String(decoding: try fixture("musicxml-multi-staff"), as: UTF8.self)
        let shortened = multi.replacingOccurrences(of: "<measure number=\"A\"><note><pitch><step>D</step><octave>5</octave></pitch><duration>8</duration></note></measure>", with: "")
        XCTAssertThrowsError(try MusicXMLScore(data: Data(shortened.utf8))) {
            guard case .unsupportedCue(.unestablishedPlayback) = $0 as? MusicXMLReadError else {
                return XCTFail("Expected mismatched part lengths to be unsupported, got \($0)")
            }
        }
    }

    func testMalformedInputDoesNotProduceATimeline() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        var inputs = [try fixture("musicxml-malformed"), Data(), Data("<score-partwise/>".utf8), Data("<other/>".utf8)]
        let replacements = [
            ("<divisions>4</divisions>", "<divisions>0</divisions>"),
            ("<divisions>4</divisions>", "<divisions>NaN</divisions>"),
            ("<divisions>4</divisions>", ""),
            ("<duration>2</duration>", "<duration>-1</duration>"),
            ("<duration>2</duration>", "<duration>0</duration>"),
            ("<duration>2</duration>", "<duration>inf</duration>"),
            ("<duration>2</duration>", ""),
            ("<note><rest/>", "<note><chord/><rest/>"),
            ("<note><pitch>", "<note><staff>0</staff><pitch>"),
            ("</attributes>", "</attributes><backup><duration>4</duration></backup>"),
            ("<step>C</step>", "<step>Z</step>"),
            ("<octave>5</octave>", ""),
            ("<note><pitch>", "<note><tie type=\"stop\"/><pitch>")
        ]
        inputs += replacements.map { Data(xml.replacingOccurrences(of: $0.0, with: $0.1).utf8) }
        for input in inputs {
            XCTAssertThrowsError(try MusicXMLScore(data: input)) {
                guard case .malformed(let detail) = $0 as? MusicXMLReadError else {
                    return XCTFail("Expected malformed input, got \($0)")
                }
                XCTAssertFalse(detail.isEmpty)
            }
        }
    }

    func testStaffIdentityAndNamesPreserveSourceTextAndRejectAmbiguousIDs() throws {
        let xml = String(decoding: try fixture("musicxml-multi-staff"), as: UTF8.self)
        let renamed = xml.replacingOccurrences(of: "<part-name>Piano</part-name>", with: "<part-name><![CDATA[  Keys & Strings  ]]></part-name>")
        let score = try MusicXMLScore(data: Data(renamed.utf8))
        XCTAssertEqual(score.staves.map(\.displayName), ["  Keys & Strings   (staff 1)", "  Keys & Strings   (staff 2)", "  Keys & Strings  "])
        XCTAssertEqual(Set(score.staves.map(\.id)).count, 3)
        let duplicateID = xml.replacingOccurrences(of: "id=\"Other\"", with: "id=\"Piano\"")
        XCTAssertThrowsError(try MusicXMLScore(data: Data(duplicateID.utf8))) {
            guard case .unsupportedCue(.unestablishedPlayback) = $0 as? MusicXMLReadError else {
                return XCTFail("Expected ambiguous staff identities to be unsupported, got \($0)")
            }
        }
        let unnamed = xml.replacingOccurrences(of: "<part-name>Piano</part-name>", with: "<part-name/>")
        XCTAssertEqual(try MusicXMLScore(data: Data(unnamed.utf8)).staves.map(\.displayName), ["Piano (staff 1)", "Piano (staff 2)", "Other"])
    }

    func testCueNotesAreSilentButHiddenPlaybackNotesRemainSounding() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        let cue = xml.replacingOccurrences(of: "<note><pitch>", with: "<note><cue/><pitch>")
        let cueScore = try MusicXMLScore(data: Data(cue.utf8))
        XCTAssertTrue(cueScore.staves[0].soundingIntervals.isEmpty)
        XCTAssertEqual(cueScore.endQuarter, 12)
        let hidden = xml.replacingOccurrences(of: "<note>", with: "<note print-object=\"no\">")
        XCTAssertEqual(try MusicXMLScore(data: Data(hidden.utf8)).staves[0].soundingIntervals.count, 3)
    }

    func testUnfinishedOrAmbiguousTiesDoNotSilentlyLoseSustains() throws {
        let xml = String(decoding: try fixture("musicxml-ties"), as: UTF8.self)
        let unfinished = xml.replacingOccurrences(of: "<duration>3</duration><tie type=\"stop\"/><voice>1</voice>", with: "<duration>3</duration><voice>1</voice>")
        let ambiguous = xml.replacingOccurrences(of: "<backup><duration>12</duration></backup>", with: "<note><chord/><pitch><step>C</step><octave>4</octave></pitch><duration>12</duration><tie type=\"start\"/><voice>1</voice></note><backup><duration>12</duration></backup>")
        for input in [unfinished, ambiguous] {
            XCTAssertThrowsError(try MusicXMLScore(data: Data(input.utf8))) {
                guard case .unsupportedCue(.unestablishedPlayback) = $0 as? MusicXMLReadError else {
                    return XCTFail("Expected ambiguous tie mapping to be unsupported, got \($0)")
                }
            }
        }
    }

    func testCrossStaffTiePreservesEachSegmentsStaffAssignment() throws {
        let score = try MusicXMLScore(data: fixture("musicxml-cross-staff-tie"))
        XCTAssertEqual(score.staves.map(\.id.staffNumber), [1, 2])
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.startQuarter), [0])
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.endQuarter), [4])
        XCTAssertEqual(score.staves[1].soundingIntervals.map(\.startQuarter), [4])
        XCTAssertEqual(score.staves[1].soundingIntervals.map(\.endQuarter), [5])
        XCTAssertEqual(score.endQuarter, 8)
    }

    func testCrossStaffTieRejectsMoreThanOnePossibleOrigin() throws {
        let xml = String(decoding: try fixture("musicxml-cross-staff-tie"), as: UTF8.self)
        let ambiguous = xml
            .replacingOccurrences(of: "<staves>2</staves>", with: "<staves>3</staves>")
            .replacingOccurrences(of: "<note><rest measure=\"yes\"/><duration>4</duration><voice>5</voice><staff>2</staff></note>", with: "<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><tie type=\"start\"/><voice>1</voice><staff>2</staff></note>")
            .replacingOccurrences(of: "<type>quarter</type><staff>2</staff>", with: "<type>quarter</type><staff>3</staff>")
        XCTAssertThrowsError(try MusicXMLScore(data: Data(ambiguous.utf8))) {
            XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.unestablishedPlayback("Ambiguous cross-staff tie.")))
        }
    }

    func testCompleteUnnumberedMeasuresAreNotPickups() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        for number in ["1", "2"] {
            let unnumbered = xml.replacingOccurrences(of: "<measure number=\"\(number)\">", with: "<measure number=\"\(number)\" implicit=\"yes\">")
            let score = try MusicXMLScore(data: Data(unnumbered.utf8))
            XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3"])
            XCTAssertEqual(score.measures.map(\.endQuarter), [4, 8, 12])
            XCTAssertEqual(score.staves[0].soundingIntervals.map(\.startQuarter), [0.5, 1, 9])
        }
    }

    func testOrdinaryFineTextIsNotAJumpButCompleteDirectivesAre() throws {
        let xml = String(decoding: try fixture("musicxml-single-staff"), as: UTF8.self)
        func withWords(_ words: String) -> Data {
            Data(xml.replacingOccurrences(of: "<measure number=\"2\">", with: "<measure number=\"2\"><direction><direction-type><words>\(words)</words></direction-type></direction>").utf8)
        }
        let score = try MusicXMLScore(data: withWords("Fine tone"))
        XCTAssertEqual(score.endQuarter, 12)
        XCTAssertEqual(score.staves[0].soundingIntervals.map(\.startQuarter), [0.5, 1, 9])
        for directive in ["Fine", " Fine. ", "D.C.", "D.C. al Fine", "D. C. al Fine", "D.S. al Coda", "Da Capo", "Dal Segno", "To Coda"] {
            XCTAssertThrowsError(try MusicXMLScore(data: withWords(directive)), directive) {
                XCTAssertEqual($0 as? MusicXMLReadError, .unsupportedCue(.repeatsOrJumps), directive)
            }
        }
    }
}
