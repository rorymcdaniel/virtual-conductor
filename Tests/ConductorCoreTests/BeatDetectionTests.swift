import XCTest
import ConductorCore

/// Original generated PCM; no owner recordings are needed for this replay.
enum BeatDetectionFixture {
    static func signal(pitches: [Int], interval: Double = 0.25, gap: Double = 0.02,
                       amplitude: Double = 0.15, rate: Double = 48000, vibrato: Double = 0) -> [Float] {
        let lead = 0.15, duration = lead + Double(pitches.count) * interval + 0.15
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        for (index, pitch) in pitches.enumerated() {
            let start = lead + Double(index) * interval, end = start + interval - gap
            let hz = 440 * pow(2, Double(pitch - 69) / 12)
            for i in Int(start * rate)..<Int(end * rate) {
                let t = Double(i) / rate - start
                let envelope = max(0, min(1, t / 0.005, (end - Double(i) / rate) / 0.005))
                // Frequency modulation, with vibrato specified as fractional Hz.
                let phase = 2 * .pi * hz * t + hz * vibrato / 5 * (1 - cos(2 * .pi * 5 * t))
                samples[i] = Float(amplitude * envelope * (sin(phase) + 0.35 * sin(2 * phase)))
            }
        }
        return samples
    }
}

final class BeatDetectionTests: XCTestCase {
    func testShortRepeatedArticulationsReachLiveTempoTracker() throws {
        let pitches = Array(repeating: 60, count: 8), midi = try FollowingFixture.midi()
        let notes = pitches.enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0), endQuarter: Double($0 + 1)) }
        for gap in [0.01, 0.015, 0.02] {
            let samples = BeatDetectionFixture.signal(pitches: pitches, interval: 0.3, gap: gap)
            var analyzer = SoloAudioAnalyzer(sampleRate: 48000), tracker = SoloTracker()
            var matches: [Int] = []
            for frame in analyzer.process(samples) {
                if let match = tracker.observe(pitch: frame.pitch, time: frame.time, notes: notes, expectedQuarter: max(0, (frame.time - 0.15) / 0.3),
                                               free: false, midi: midi, rearticulated: frame.rearticulated) { matches.append(match) }
            }
            XCTAssertEqual(matches, Array(0..<8), "Gap \(gap)")
            XCTAssertEqual(tracker.rate, 0.5 / 0.3, accuracy: 0.04)
        }
    }

    func testVibratoAndAnOccasionalWrongNoteStillRevealTempo() throws {
        let pitches = [60,62,64,65,67,65,64,62]
        var played = pitches; played[3] = 66
        let pace = 1.06, rate = 48000.0
        let samples = BeatDetectionFixture.signal(pitches: played, interval: 0.25 / pace, rate: rate, vibrato: 0.015)
        let notes = pitches.enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0) / 2, endQuarter: Double($0 + 1) / 2) }
        var analyzer = SoloAudioAnalyzer(sampleRate: rate), tracker = SoloTracker()
        let midi = try FollowingFixture.midi()
        for frame in analyzer.process(samples) {
            tracker.observe(pitch: frame.pitch, time: frame.time, notes: notes, expectedQuarter: max(0, (frame.time - 0.15) * 2),
                            free: false, midi: midi, rearticulated: frame.rearticulated)
        }
        XCTAssertEqual(tracker.index, 7)
        XCTAssertEqual(tracker.rate, pace, accuracy: 0.04)
        let result = try Interpretation.analyze(samples: samples, sampleRate: rate, reference: notes, range: PassageRange(start: 0, end: 4))
        XCTAssertEqual(result.matched, 7)
        for beat in result.beats { XCTAssertEqual(beat.time, 0.15 + beat.quarter * 0.5 / pace, accuracy: 0.04) }
    }

    func testRealtimeAnalysisBudget() {
        let rate = 48000.0
        let samples = BeatDetectionFixture.signal(pitches: Array(repeating: [48,60,60,67], count: 8).flatMap { $0 }, rate: rate)
        var analyzer = SoloAudioAnalyzer(sampleRate: rate), durations: [Double] = []
        for start in stride(from: 0, to: samples.count, by: 480) {
            let block = Array(samples[start..<min(samples.count, start + 480)])
            let begin = ProcessInfo.processInfo.systemUptime
            _ = analyzer.process(block)
            durations.append(ProcessInfo.processInfo.systemUptime - begin)
        }
        let total = durations.reduce(0, +), duration = Double(samples.count) / rate
        let p99 = durations.sorted()[Int(Double(durations.count - 1) * 0.99)]
        print(String(format: "Audio analysis: %.3f s audio / %.4f s CPU wall time; 10 ms block p99 %.3f ms", duration, total, p99 * 1000))
        XCTAssertLessThan(total, duration * 0.25, "Analysis must leave substantial real-time headroom")
        XCTAssertLessThan(p99, 0.01, "99% of blocks must complete within the 10 ms hop")
    }

    func testSampleClockIsIndependentOfDeliveryChunks() {
        let samples = BeatDetectionFixture.signal(pitches: [48, 60, 60, 67, 65, 62], rate: 44100)
        var whole = SoloAudioAnalyzer(sampleRate: 44100)
        let expected = whole.process(samples)
        var streaming = SoloAudioAnalyzer(sampleRate: 44100), actual: [SoloObservation] = []
        for start in stride(from: 0, to: samples.count, by: 1024) {
            actual += streaming.process(Array(samples[start..<min(samples.count, start + 1024)]))
        }
        XCTAssertEqual(actual, expected)
    }

    func testNoiseDCAndSilenceDoNotInventNotes() {
        var seed: UInt64 = 42
        let noise = (0..<24000).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.002
        }
        for samples in [noise, [Float](repeating: 0.1, count: 24000), [Float](repeating: 0, count: 24000)] {
            XCTAssertTrue(Interpretation.detectNotes(samples: samples, sampleRate: 48000).isEmpty)
        }
    }

    func testPhraseTempoAcrossRegistersRatesAndArticulations() throws {
        let midi = try FollowingFixture.midi()
        for rate in [8000.0, 44100, 48000, 96000] {
            for (pitches, interval, gap) in [([48,50,52,53,55,53,52,50], 0.3, 0.02),
                                             ([60,62,64,65,67,65,64,62], 0.125, 0.0),
                                             ([72,72,74,74,76,76,74,72], 0.2, 0.02)] {
                let samples = BeatDetectionFixture.signal(pitches: pitches, interval: interval, gap: gap, rate: rate)
                let notes = pitches.enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0) / 2, endQuarter: Double($0 + 1) / 2) }
                var analyzer = SoloAudioAnalyzer(sampleRate: rate), tracker = SoloTracker()
                var attacks: [(Int, Double)] = []
                for frame in analyzer.process(samples) {
                    if let index = tracker.observe(pitch: frame.pitch, time: frame.time, notes: notes,
                                                   expectedQuarter: max(0, (frame.time - 0.15) / interval / 2),
                                                   free: false, midi: midi, rearticulated: frame.rearticulated) {
                        attacks.append((index, tracker.lastAttack))
                    }
                }
                XCTAssertEqual(attacks.map { $0.0 }, Array(pitches.indices), "rate \(rate), pitches \(pitches)")
                for (index, time) in attacks { XCTAssertEqual(time, 0.15 + Double(index) * interval, accuracy: 0.04) }
                XCTAssertEqual(tracker.rate, 0.25 / interval, accuracy: 0.04)
                let result = try Interpretation.analyze(samples: samples, sampleRate: rate, reference: notes,
                                                      range: PassageRange(start: 0, end: 4))
                for beat in result.beats { XCTAssertEqual(beat.time, 0.15 + beat.quarter * interval * 2, accuracy: 0.04) }
            }
        }
    }

    func testTonguedPhraseWithHeadphoneLeakage() throws {
        let pitches = [60,60,62,62,64,64,62,60], rate = 48000.0
        var samples = BeatDetectionFixture.signal(pitches: pitches, rate: rate)
        for i in samples.indices { samples[i] += Float(0.002 * sin(2 * .pi * 233 * Double(i) / rate)) }
        let reference = pitches.enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0), endQuarter: Double($0 + 1)) }
        let result = try Interpretation.analyze(samples: samples, sampleRate: rate, reference: reference, range: PassageRange(start: 0, end: 8))
        XCTAssertEqual(result.matched, 8)
        for beat in result.beats { XCTAssertEqual(beat.time, 0.15 + beat.quarter * 0.25, accuracy: 0.04) }
    }

    func testRecordedRepeatedTonguedNotesRetainEveryBeat() throws {
        let pitches = [Int](repeating: 60, count: 8)
        let samples = BeatDetectionFixture.signal(pitches: pitches)
        let notes = Interpretation.detectNotes(samples: samples, sampleRate: 48000)
        XCTAssertEqual(notes.count, pitches.count)
        let reference = pitches.enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0), endQuarter: Double($0 + 1)) }
        let result = try Interpretation.analyze(samples: samples, sampleRate: 48000, reference: reference,
                                              range: PassageRange(start: 0, end: 8))
        for beat in result.beats {
            XCTAssertEqual(beat.time, 0.15 + beat.quarter * 0.25, accuracy: 0.04)
        }
    }

    func testQuietRecordedPhraseStillYieldsTempo() throws {
        let pitches = [60, 62, 64, 65, 67, 65, 64, 62]
        let samples = BeatDetectionFixture.signal(pitches: pitches, amplitude: 0.002)
        let detected = Interpretation.detectNotes(samples: samples, sampleRate: 48000)
        XCTAssertEqual(detected.map(\.pitch), pitches)
    }
}
