import SwiftUI
import ConductorCore

struct PracticeTempoView: View {
    @ObservedObject var model: PerformanceModel
    @State private var measure: String
    @State private var beat: String
    @State private var bpm: String
    @State private var error = ""
    @State private var undoDeletes: [PracticeTempo.Edits] = []

    init(model: PerformanceModel) {
        self.model = model
        let q = model.tempoEditorQuarter
        _measure = State(initialValue: String(Int(q / 4) + 1))
        _beat = State(initialValue: Self.number(q.truncatingRemainder(dividingBy: 4) + 1, precision: 7))
        _bpm = State(initialValue: Self.number(model.prepared?.practice.bpm(atQuarter: q) ?? 120))
    }

    private static func number(_ value: Double, precision: Int = 3) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...precision)))
    }
    static func location(_ q: Double) -> String {
        "Measure \(Int(q / 4) + 1), beat \(number(q.truncatingRemainder(dividingBy: 4) + 1, precision: 7))"
    }
    private var quarter: Double? {
        guard let midi = model.prepared?.midi, let m = Int(measure), (1...midi.measures).contains(m),
              let b = Double(beat), (1..<5).contains(b) else { return nil }
        let ticks = ((Double(m - 1) * 4 + b - 1) * Double(midi.ppqn)).rounded()
        let q = ticks / Double(midi.ppqn)
        return q < midi.endQuarter ? q : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Practice tempo").font(.title2.bold())
            if let practice = model.prepared?.practice {
                TempoMapView(entries: practice.entries, end: practice.planned.endQuarter, selected: quarter, select: select,
                             delete: { entry, includeSteps in
                                 changeMap(practice.deleting(entry, includingTempoSteps: includeSteps))
                             }, hasFollowingSteps: practice.hasFollowingSteps)
                if !undoDeletes.isEmpty || !practice.deleted.isEmpty {
                    HStack {
                        if let previous = undoDeletes.last {
                            Button("Undo") { changeMap(previous, undoing: true) }
                        }
                        if !practice.deleted.isEmpty {
                            Button("Restore deleted score entries") { changeMap(.init(marks: practice.marks)) }
                        }
                    }
                }
                Divider()
            }
            HStack {
                Text("Measure")
                TextField("Measure", text: $measure).frame(width: 60)
                Text("Beat")
                TextField("Beat", text: $beat).frame(width: 60)
                Text("♩ =")
                TextField("BPM", text: $bpm).frame(width: 72)
                Text("BPM")
            }
            .textFieldStyle(.roundedBorder)
            if let q = quarter, let practice = model.prepared?.practice {
                if let next = practice.nextMark(after: q) {
                    Text("Applies until \(Self.location(next).lowercased()), where ♩ = \(Self.number(practice.bpm(atQuarter: next))).")
                } else { Text("Applies through the end of the piece.") }
            }
            if let timing = model.prepared?.timing, quarter != timing.startQuarter {
                Button("Use rehearsal start · measure \(timing.startMeasure)") {
                    measure = String(timing.startMeasure)
                    beat = "1"
                }
            }
            if let last = model.following.lastFollowedBPM {
                Button("Use last followed tempo · \(Self.number(last)) BPM") { bpm = Self.number(last) }
            }
            if let marks = model.prepared?.practice.marks, let q = quarter, marks.contains(where: { $0.quarter == q }) {
                Button("Remove practice marking") { save(marks.filter { $0.quarter != q }) }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Close") { model.tempoOpen = false }.keyboardShortcut(.cancelAction)
                Button("Set tempo") {
                    guard let q = quarter, let value = Double(bpm), let practice = model.prepared?.practice else {
                        error = "Enter a measure in this score, a beat from 1 up to (but below) 5, and a tempo in BPM."
                        return
                    }
                    save(practice.marks.filter { $0.quarter != q } + [PracticeTempoMark(quarter: q, bpm: value)])
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 680)
        .onChange(of: quarter) { _, q in
            error = ""
            if let q, let practice = model.prepared?.practice { bpm = Self.number(practice.bpm(atQuarter: q)) }
        }
    }

    private func select(_ entry: PracticeTempo.Entry) {
        measure = String(Int(entry.quarter / 4) + 1)
        beat = Self.number(entry.quarter.truncatingRemainder(dividingBy: 4) + 1, precision: 7)
        bpm = Self.number(entry.bpm)
    }

    private func changeMap(_ edits: PracticeTempo.Edits, undoing: Bool = false) {
        guard let before = model.prepared?.practice.edits else { return }
        do {
            try model.saveTempoEdits(edits)
            if undoing { undoDeletes.removeLast() } else { undoDeletes.append(before) }
            if let q = quarter, let practice = model.prepared?.practice { bpm = Self.number(practice.bpm(atQuarter: q)) }
            error = ""
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ marks: [PracticeTempoMark]) {
        do {
            try model.saveTempoMarks(marks)
            model.tempoOpen = false
        } catch { self.error = error.localizedDescription }
    }
}
