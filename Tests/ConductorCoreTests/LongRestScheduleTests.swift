import Foundation
import XCTest
import ConductorCore

final class LongRestScheduleTests: XCTestCase {
    private let solo = MusicXMLStaffID(partID: "Solo", staffNumber: 1)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "musicxml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testEightFullRestsCueOnContainingBeatAndRetainProgressUntilOffbeatEntrance() throws {
        let score = try MusicXMLScore(data: fixture("long-rest-eight-measures"))
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 8)
        XCTAssertEqual(schedule.staffID, solo)
        XCTAssertEqual(schedule.threshold, 8)
        XCTAssertEqual(schedule.runs.count, 1)
        let run = try XCTUnwrap(schedule.runs.first)
        XCTAssertEqual(run.fullRestMeasures.map(\.number), ["1", "2", "3", "4", "5", "6", "7", "8"])
        XCTAssertEqual(run.fullMeasureCount, 8)
        XCTAssertEqual(run.startQuarter, 0)
        XCTAssertEqual(run.endQuarter, 34.5)
        XCTAssertEqual(run.entrance?.measureIndex, 8)
        XCTAssertEqual(run.entrance?.measureNumber, "9")
        XCTAssertEqual(run.entrance?.beat, 3.5)
        XCTAssertEqual(run.entrance?.quarter, 34.5)
        XCTAssertEqual(run.cue?.measureIndex, 8)
        XCTAssertEqual(run.cue?.measureNumber, "9")
        XCTAssertEqual(run.cue?.beat, 3)
        XCTAssertEqual(run.cue?.quarter, 34)
        XCTAssertNil(schedule.progress(atQuarter: -0.001))
        for (quarter, currentMeasure) in [(0.0, 1), (3.999, 1), (4, 2), (27.999, 7), (28, 8), (31.999, 8), (32, 8), (33.999, 8), (34, 8), (34.499, 8)] {
            let progress = try XCTUnwrap(schedule.progress(atQuarter: quarter))
            XCTAssertEqual(progress.currentMeasure, currentMeasure, "quarter \(quarter)")
            XCTAssertEqual(progress.run, run)
        }
        XCTAssertNil(schedule.progress(atQuarter: 34.5))
        XCTAssertNil(schedule.progress(atQuarter: 35))
        XCTAssertNil(schedule.progress(atQuarter: 36))
    }

    func testThresholdIncludesEqualAndLongerRunsButExcludesShorterRuns() throws {
        let score = try MusicXMLScore(data: fixture("long-rest-eight-measures"))
        for threshold in [1, 7, 8] {
            let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: threshold)
            XCTAssertEqual(schedule.runs.map(\.fullMeasureCount), [8])
            XCTAssertEqual(schedule.progress(atQuarter: 0)?.currentMeasure, 1)
        }
        for threshold in [9, Int.max] {
            let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: threshold)
            XCTAssertTrue(schedule.runs.isEmpty)
            XCTAssertNil(schedule.progress(atQuarter: 0))
        }
        for threshold in [0, -1, Int.min] {
            XCTAssertThrowsError(try LongRestSchedule(score: score, staffID: solo, threshold: threshold)) {
                XCTAssertEqual($0 as? LongRestScheduleError, .invalidThreshold)
            }
        }
    }

    func testOnBeatEntrancesCueAtTheEntranceIncludingTheNextDownbeat() throws {
        let xml = String(decoding: try fixture("long-rest-eight-measures"), as: UTF8.self)
        let onBeat = xml.replacingOccurrences(of: "<duration>5</duration>", with: "<duration>4</duration>")
            .replacingOccurrences(of: "<duration>3</duration>", with: "<duration>4</duration>")
        let downbeat = xml.replacingOccurrences(of: "<note><rest/><duration>5</duration></note>", with: "")
            .replacingOccurrences(of: "<duration>3</duration>", with: "<duration>8</duration>")
        for (input, beat, quarter) in [(onBeat, 3.0, 34.0), (downbeat, 1.0, 32.0)] {
            let score = try MusicXMLScore(data: Data(input.utf8))
            let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 8)
            let run = try XCTUnwrap(schedule.runs.first)
            XCTAssertEqual(run.fullMeasureCount, 8)
            XCTAssertEqual(run.cue, run.entrance)
            XCTAssertEqual(run.cue?.beat, beat)
            XCTAssertEqual(run.cue?.quarter, quarter)
            XCTAssertEqual(schedule.progress(atQuarter: quarter.nextDown)?.currentMeasure, 8)
            XCTAssertNil(schedule.progress(atQuarter: quarter))
        }
    }

    func testPartialMeasuresDoNotCountAndSoundingNotesSeparateRestRuns() throws {
        let score = try MusicXMLScore(data: fixture("long-rest-separated-runs"))
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 2)
        XCTAssertEqual(schedule.runs.map(\.fullMeasureCount), [2, 2])
        XCTAssertEqual(schedule.runs.map { $0.fullRestMeasures.map(\.number) }, [["2", "3"], ["7", "8"]])
        XCTAssertEqual(schedule.runs.map(\.startQuarter), [4, 24])
        XCTAssertEqual(schedule.runs.map(\.endQuarter), [14, 32])
        XCTAssertEqual(schedule.runs.map { $0.entrance?.quarter }, [14, 32])
        XCTAssertEqual(schedule.runs.map { $0.cue?.quarter }, [14, 32])
        for quarter in [0.0, 1, 3.999, 14, 15, 16, 20, 21, 23.999, 32, 34, 36, 39.999, 40] {
            XCTAssertNil(schedule.progress(atQuarter: quarter), "quarter \(quarter)")
        }
        for (quarter, numerator) in [(4.0, 1), (7.999, 1), (8, 2), (12, 2), (13.999, 2), (24, 1), (28, 2), (31.999, 2)] {
            XCTAssertEqual(schedule.progress(atQuarter: quarter)?.currentMeasure, numerator, "quarter \(quarter)")
        }
        XCTAssertTrue(try LongRestSchedule(score: score, staffID: solo, threshold: 3).runs.isEmpty)
    }

    func testTrailingRestHasProgressUntilScoreEndWithoutAnInventedCue() throws {
        let score = try MusicXMLScore(data: fixture("long-rest-separated-runs"))
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 1)
        XCTAssertEqual(schedule.runs.map(\.fullMeasureCount), [2, 1, 2, 1])
        let trailing = try XCTUnwrap(schedule.runs.last)
        XCTAssertEqual(trailing.fullRestMeasures.map(\.number), ["10"])
        XCTAssertEqual(trailing.startQuarter, 36)
        XCTAssertEqual(trailing.endQuarter, 40)
        XCTAssertNil(trailing.entrance)
        XCTAssertNil(trailing.cue)
        XCTAssertNil(schedule.progress(atQuarter: 35.999))
        XCTAssertEqual(schedule.progress(atQuarter: 36)?.currentMeasure, 1)
        XCTAssertEqual(schedule.progress(atQuarter: 39.999)?.run, trailing)
        XCTAssertNil(schedule.progress(atQuarter: 40))
        XCTAssertNil(schedule.progress(atQuarter: 41))
    }

    func testAllSelectedStaffVoicesAndTiesCountAsSoundingButOtherStavesDoNot() throws {
        let score = try MusicXMLScore(data: fixture("long-rest-voices-and-staves"))
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 1)
        XCTAssertEqual(schedule.runs.count, 1)
        let run = try XCTUnwrap(schedule.runs.first)
        XCTAssertEqual(run.fullRestMeasures.map(\.number), ["3"])
        XCTAssertEqual(run.startQuarter, 8)
        XCTAssertEqual(run.endQuarter, 14.5)
        XCTAssertEqual(run.entrance?.beat, 3.5)
        XCTAssertEqual(run.cue?.quarter, 14)
        XCTAssertEqual(run.cue?.beat, 3)
        for quarter in [0.0, 2, 4, 5.999, 6, 7.999] {
            XCTAssertNil(schedule.progress(atQuarter: quarter), "quarter \(quarter)")
        }
        XCTAssertEqual(schedule.progress(atQuarter: 8)?.currentMeasure, 1)
        XCTAssertEqual(schedule.progress(atQuarter: 14.499)?.currentMeasure, 1)
        XCTAssertNil(schedule.progress(atQuarter: 14.5))
        for staffID in [MusicXMLStaffID(partID: "Solo", staffNumber: 2), MusicXMLStaffID(partID: "Other", staffNumber: 1)] {
            XCTAssertTrue(try LongRestSchedule(score: score, staffID: staffID, threshold: 1).runs.isEmpty)
        }
        let unknown = MusicXMLStaffID(partID: "Other", staffNumber: 2)
        XCTAssertThrowsError(try LongRestSchedule(score: score, staffID: unknown, threshold: 1)) {
            XCTAssertEqual($0 as? LongRestScheduleError, .unknownStaff(unknown))
        }
    }

    func testSustainsAcrossWholeMeasuresAndNotesEndingAtBarlinesAreNotRests() throws {
        let tiedXML = String(decoding: try fixture("musicxml-ties"), as: UTF8.self)
        let extended = tiedXML.replacingOccurrences(of: "</part>", with: """
        <measure number="4"><note><rest measure="yes"/><duration>12</duration></note></measure>
        <measure number="5"><note><pitch><step>D</step><octave>5</octave></pitch><duration>12</duration></note></measure>
        </part>
        """)
        let score = try MusicXMLScore(data: Data(extended.utf8))
        let staffID = try XCTUnwrap(score.staves.first?.id)
        let schedule = try LongRestSchedule(score: score, staffID: staffID, threshold: 1)
        XCTAssertEqual(schedule.runs.map { $0.fullRestMeasures.map(\.number) }, [["4"]])
        XCTAssertEqual(schedule.runs.first?.startQuarter, 12)
        XCTAssertEqual(schedule.runs.first?.endQuarter, 16)
        XCTAssertEqual(schedule.runs.first?.cue?.quarter, 16)
        XCTAssertNil(schedule.progress(atQuarter: 8))
        XCTAssertNil(schedule.progress(atQuarter: 9))

        let xml = String(decoding: try fixture("long-rest-voices-and-staves"), as: UTF8.self)
        let endingAtBarline = xml.replacingOccurrences(of: "<duration>4</duration><tie type=\"stop\"/>", with: "<duration>8</duration><tie type=\"stop\"/>")
            .replacingOccurrences(of: "<note><rest/><duration>4</duration><voice>2</voice><staff>1</staff></note>", with: "")
        let barlineScore = try MusicXMLScore(data: Data(endingAtBarline.utf8))
        let barlineSchedule = try LongRestSchedule(score: barlineScore, staffID: solo, threshold: 1)
        XCTAssertEqual(barlineSchedule.runs.map { $0.fullRestMeasures.map(\.number) }, [["3"]])
        XCTAssertNil(barlineSchedule.progress(atQuarter: 8.nextDown))
        XCTAssertEqual(barlineSchedule.progress(atQuarter: 8)?.currentMeasure, 1)
    }

    func testEntirelySilentStaffHasOneRunWithoutAnEntranceAndQueriesAreStateless() throws {
        let xml = String(decoding: try fixture("long-rest-eight-measures"), as: UTF8.self)
            .replacingOccurrences(of: "<pitch><step>C</step><octave>5</octave></pitch>", with: "<rest/>")
        let score = try MusicXMLScore(data: Data(xml.utf8))
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 9)
        XCTAssertEqual(schedule.runs.map(\.fullMeasureCount), [9])
        XCTAssertEqual(schedule.runs.first?.endQuarter, 36)
        XCTAssertNil(schedule.runs.first?.entrance)
        XCTAssertNil(schedule.runs.first?.cue)
        for quarter in [Double.nan, .infinity, -.infinity, -1, 36, 100] {
            XCTAssertNil(schedule.progress(atQuarter: quarter))
        }
        for (quarter, numerator) in [(35.0, 9), (0, 1), (16, 5), (4, 2), (35, 9), (0, 1)] {
            XCTAssertEqual(schedule.progress(atQuarter: quarter)?.currentMeasure, numerator)
        }
        XCTAssertEqual(try LongRestSchedule(score: score, staffID: solo, threshold: 9), schedule)
    }

    func testRawStaffIDsAndDuplicateOrEmptyMeasureLabelsArePreserved() throws {
        var xml = String(decoding: try fixture("long-rest-eight-measures"), as: UTF8.self)
            .replacingOccurrences(of: "id=\"Solo\"", with: "id=\" Solo &amp; I \"")
        for number in 1...9 {
            xml = xml.replacingOccurrences(of: "number=\"\(number)\"", with: "number=\" A &amp; B \"")
        }
        let staffID = MusicXMLStaffID(partID: " Solo & I ", staffNumber: 1)
        let score = try MusicXMLScore(data: Data(xml.utf8))
        let schedule = try LongRestSchedule(score: score, staffID: staffID, threshold: 8)
        let run = try XCTUnwrap(schedule.runs.first)
        XCTAssertEqual(schedule.staffID.partID, " Solo & I ")
        XCTAssertEqual(run.fullRestMeasures.map(\.number), Array(repeating: " A & B ", count: 8))
        XCTAssertEqual(run.entrance?.measureIndex, 8)
        XCTAssertEqual(run.entrance?.measureNumber, " A & B ")
        XCTAssertEqual(run.cue?.measureNumber, " A & B ")
        let unlabeled = xml.replacingOccurrences(of: " number=\" A &amp; B \"", with: "")
        let unlabeledScore = try MusicXMLScore(data: Data(unlabeled.utf8))
        let unlabeledSchedule = try LongRestSchedule(score: unlabeledScore, staffID: staffID, threshold: 8)
        XCTAssertEqual(unlabeledSchedule.runs.first?.entrance?.measureNumber, "")
        XCTAssertEqual(unlabeledSchedule.runs.first?.entrance?.measureIndex, 8)
    }

    func testAccumulatedTripletRestsCueOnTheIntendedWholeBeat() throws {
        let rests = String(repeating: "<note><rest/><duration>1</duration></note>", count: 18)
        let xml = """
        <score-partwise><part id="Solo">
        <measure number="1"><attributes><divisions>6</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes><note><rest/><duration>24</duration></note></measure>
        <measure number="2">\(rests)<note><pitch><step>C</step><octave>5</octave></pitch><duration>6</duration></note></measure>
        </part></score-partwise>
        """
        let score = try MusicXMLScore(data: Data(xml.utf8))
        let rawEntrance = try XCTUnwrap(score.staves.first?.soundingIntervals.first?.startQuarter)
        XCTAssertEqual(rawEntrance, 6.999999999999999)
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 1)
        let run = try XCTUnwrap(schedule.runs.first)
        XCTAssertEqual(run.cue?.quarter, 7)
        XCTAssertEqual(run.cue?.beat, 4)
        XCTAssertEqual(run.entrance, run.cue)
        XCTAssertEqual(schedule.progress(atQuarter: 7.nextDown)?.currentMeasure, 1)
        XCTAssertNil(schedule.progress(atQuarter: 7))
        XCTAssertEqual(score.staves.first?.soundingIntervals.first?.startQuarter, rawEntrance)
    }

    func testAccumulatedFifthsEndingAtBarlineDoNotEraseTheNextFullRest() throws {
        let rests = String(repeating: "<note><rest/><duration>1</duration></note>", count: 19)
        let xml = """
        <score-partwise><part id="Solo">
        <measure number="1"><attributes><divisions>5</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>\(rests)<note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration></note></measure>
        <measure number="2"><note><rest/><duration>20</duration></note></measure>
        </part></score-partwise>
        """
        let score = try MusicXMLScore(data: Data(xml.utf8))
        let rawEnd = try XCTUnwrap(score.staves.first?.soundingIntervals.first?.endQuarter)
        XCTAssertEqual(rawEnd, 4.000000000000001)
        let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 1)
        XCTAssertEqual(schedule.runs.map { $0.fullRestMeasures.map(\.number) }, [["2"]])
        XCTAssertEqual(schedule.progress(atQuarter: 4)?.currentMeasure, 1)
        XCTAssertEqual(schedule.progress(atQuarter: 8.nextDown)?.currentMeasure, 1)
        XCTAssertNil(schedule.progress(atQuarter: 8))
        XCTAssertNil(schedule.runs.first?.entrance)
        XCTAssertNil(schedule.runs.first?.cue)
        XCTAssertEqual(score.staves.first?.soundingIntervals.first?.endQuarter, rawEnd)
    }

    func testGenuineNonBinaryOffbeatsKeepTheirPositionsAndContainingBeats() throws {
        for (divisions, restDuration, noteDuration, entranceQuarter, cueQuarter) in [
            (3, 8, 4, 6.666666666666666, 6.0),
            (3, 10, 2, 7.333333333333334, 7.0),
            (5, 14, 6, 6.8, 6.0),
            (100_000_000, 299_999_999, 100_000_001, 6.99999999, 6.0),
            (100_000_000, 300_000_001, 99_999_999, 7.00000001, 7.0)
        ] {
            let xml = """
            <score-partwise><part id="Solo">
            <measure number="1"><attributes><divisions>\(divisions)</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes><note><rest measure="yes"/><duration>\(divisions * 4)</duration></note></measure>
            <measure number="2"><note><rest/><duration>\(restDuration)</duration></note><note><pitch><step>C</step><octave>5</octave></pitch><duration>\(noteDuration)</duration></note></measure>
            </part></score-partwise>
            """
            let score = try MusicXMLScore(data: Data(xml.utf8))
            let rawEntrance = try XCTUnwrap(score.staves.first?.soundingIntervals.first?.startQuarter)
            let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 1)
            let run = try XCTUnwrap(schedule.runs.first)
            XCTAssertEqual(try XCTUnwrap(run.entrance?.quarter), entranceQuarter, accuracy: 1e-12)
            XCTAssertEqual(run.entrance?.quarter, rawEntrance)
            XCTAssertEqual(run.cue?.quarter, cueQuarter)
            XCTAssertEqual(run.endQuarter, rawEntrance)
            XCTAssertEqual(schedule.progress(atQuarter: rawEntrance.nextDown)?.currentMeasure, 1)
            XCTAssertNil(schedule.progress(atQuarter: rawEntrance))
        }
    }

    func testShortSoundingIntervalsAtEitherBarlineStillSeparateRestRuns() throws {
        let note = "<note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration></note>"
        let rest = "<note><rest/><duration>7999999999</duration></note>"
        for (secondMeasure, entranceQuarter, cueQuarter) in [
            (note + rest, 4.0, 4.0),
            (rest + note, 7.9999999995, 7.0)
        ] {
            let xml = """
            <score-partwise><part id="Solo">
            <measure number="1"><attributes><divisions>2000000000</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes><note><rest/><duration>8000000000</duration></note></measure>
            <measure number="2">\(secondMeasure)</measure>
            <measure number="3"><note><rest/><duration>8000000000</duration></note></measure>
            </part></score-partwise>
            """
            let score = try MusicXMLScore(data: Data(xml.utf8))
            let schedule = try LongRestSchedule(score: score, staffID: solo, threshold: 1)
            XCTAssertEqual(schedule.runs.map { $0.fullRestMeasures.map(\.number) }, [["1"], ["3"]])
            XCTAssertEqual(schedule.runs.first?.entrance?.quarter, entranceQuarter)
            XCTAssertEqual(schedule.runs.first?.cue?.quarter, cueQuarter)
            XCTAssertEqual(schedule.runs.first?.endQuarter, entranceQuarter)
            XCTAssertEqual(schedule.progress(atQuarter: entranceQuarter.nextDown)?.currentMeasure, 1)
            XCTAssertNil(schedule.progress(atQuarter: entranceQuarter))
            XCTAssertNil(schedule.progress(atQuarter: 8.nextDown))
            XCTAssertEqual(schedule.progress(atQuarter: 8)?.run.fullRestMeasures.map(\.number), ["3"])
            XCTAssertNil(schedule.runs.last?.entrance)
            XCTAssertNil(schedule.runs.last?.cue)
            XCTAssertTrue(try LongRestSchedule(score: score, staffID: solo, threshold: 2).runs.isEmpty)
        }
    }
}
