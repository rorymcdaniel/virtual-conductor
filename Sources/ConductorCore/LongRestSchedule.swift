public enum LongRestScheduleError: Error, Equatable, Sendable {
    case invalidThreshold
    case unknownStaff(MusicXMLStaffID)
}

public struct LongRestSchedule: Equatable, Sendable {
    public struct Position: Equatable, Sendable {
        public let measureIndex: Int
        public let measureNumber: String
        public let beat: Double
        public let quarter: Double
    }

    public struct Run: Equatable, Sendable {
        public let fullRestMeasures: [MusicXMLMeasure]
        public let startQuarter: Double
        public let endQuarter: Double
        public let entrance: Position?
        public let cue: Position?
        public var fullMeasureCount: Int { fullRestMeasures.count }
    }

    public struct Progress: Equatable, Sendable {
        public let run: Run
        public let currentMeasure: Int
    }

    public let staffID: MusicXMLStaffID
    public let threshold: Int
    public let runs: [Run]

    public init(score: MusicXMLScore, staffID: MusicXMLStaffID, threshold: Int) throws {
        guard threshold > 0 else { throw LongRestScheduleError.invalidThreshold }
        guard let staff = score.staves.first(where: { $0.id == staffID }) else {
            throw LongRestScheduleError.unknownStaff(staffID)
        }
        self.staffID = staffID
        self.threshold = threshold
        let soundingIntervals = staff.soundingIntervals.map {
            let start = Self.beatBoundaryQuarter($0.startQuarter)
            let end = Self.beatBoundaryQuarter($0.endQuarter)
            return start < end ? MusicXMLSoundingInterval(startQuarter: start, endQuarter: end) : $0
        }
        var runs: [Run] = []
        var fullRestMeasures: [MusicXMLMeasure] = []
        for measure in score.measures {
            let sounding = soundingIntervals.contains {
                $0.startQuarter < measure.endQuarter && measure.startQuarter < $0.endQuarter
            }
            if !sounding {
                fullRestMeasures.append(measure)
            } else {
                if fullRestMeasures.count >= threshold {
                    let entranceQuarter = soundingIntervals
                        .filter { $0.startQuarter >= measure.startQuarter }
                        .map(\.startQuarter).min()!
                    let entrance = Position(measureIndex: score.measures.firstIndex(of: measure)!, measureNumber: measure.number,
                                            beat: entranceQuarter - measure.startQuarter + 1, quarter: entranceQuarter)
                    let cueQuarter = measure.startQuarter + (entranceQuarter - measure.startQuarter).rounded(.down)
                    let cue = Position(measureIndex: entrance.measureIndex, measureNumber: measure.number,
                                       beat: cueQuarter - measure.startQuarter + 1, quarter: cueQuarter)
                    runs.append(Run(fullRestMeasures: fullRestMeasures, startQuarter: fullRestMeasures[0].startQuarter,
                                    endQuarter: entranceQuarter, entrance: entrance, cue: cue))
                }
                fullRestMeasures.removeAll()
            }
        }
        if fullRestMeasures.count >= threshold {
            runs.append(Run(fullRestMeasures: fullRestMeasures, startQuarter: fullRestMeasures[0].startQuarter,
                            endQuarter: score.endQuarter, entrance: nil, cue: nil))
        }
        self.runs = runs
    }

    private static func beatBoundaryQuarter(_ quarter: Double) -> Double {
        let beat = quarter.rounded()
        return abs(quarter - beat) < 1e-9 ? beat : quarter
    }

    public func progress(atQuarter quarter: Double) -> Progress? {
        guard let run = runs.first(where: { $0.startQuarter <= quarter && quarter < $0.endQuarter }) else { return nil }
        let currentMeasure = run.fullRestMeasures.filter { $0.startQuarter <= quarter }.count
        return Progress(run: run, currentMeasure: currentMeasure)
    }
}
