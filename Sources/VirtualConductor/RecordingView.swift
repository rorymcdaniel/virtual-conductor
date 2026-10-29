import SwiftUI
import ConductorCore

@MainActor
struct RecordingView: View {
    @ObservedObject var model: RecordingModel
    var onClose: () -> Void

    private var locked: Bool { model.busy || model.recording }
    private var duration: Double { model.take?.duration ?? 0 }
    private var validBeatMap: Bool {
        do { try Interpretation.validate(model.beats, duration: duration); return true }
        catch { return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Record an interpretation").font(.title2.weight(.semibold))
                    Text("Play your solo freely, then review a draft of its beat timing.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    passageSection
                    inputSection
                    if let take = model.take {
                        takeSection(take)
                        draftSection
                        if !model.beats.isEmpty { reviewSection }
                    }
                }.padding(.trailing, 8)
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message.isEmpty ? "Enable your input to check the level before recording." : model.message)
                    .font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }.frame(minHeight: 32, alignment: .topLeading)
        }
        .padding(24)
        .frame(minWidth: 820, idealWidth: 880, minHeight: 690, idealHeight: 780)
    }

    private var passageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    positionFields("From", measure: $model.startMeasure, beat: $model.startBeat)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    positionFields("To", measure: $model.endMeasure, beat: $model.endBeat)
                    Spacer(minLength: 0)
                }.disabled(locked)
                Text("The end is a beat boundary. Choose up to 32 measures in 4/4. Changes apply to your next take.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        } label: { Label("Passage", systemImage: "music.note.list") }
    }

    private func positionFields(_ title: String, measure: Binding<Int>, beat: Binding<Int>) -> some View {
        HStack(spacing: 7) {
            Text(title).frame(width: 34, alignment: .leading)
            Text("Measure").foregroundStyle(.secondary)
            RecordingNumberField("Measure", value: Double(measure.wrappedValue), integer: true) {
                measure.wrappedValue = $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : 0
            }.frame(width: 58).textFieldStyle(.roundedBorder)
            Text("Beat").foregroundStyle(.secondary)
            Picker("Beat", selection: beat) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                .labelsHidden().frame(width: 60)
        }.font(.callout)
    }

    private var inputSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Input", selection: $model.inputID) {
                        Text("System default input").tag(UInt32(0))
                        ForEach(model.inputs) { input in Text(input.name).tag(input.id) }
                    }.disabled(locked)
                        .onChange(of: model.inputID) { _, _ in model.changeInput() }
                    Button(model.inputReady ? "Re-enable input" : "Enable input", action: model.enableInput)
                        .disabled(locked)
                }
                HStack(spacing: 12) {
                    ProgressView(value: Double(min(1, max(0, model.level))), total: 1)
                        .tint(model.level >= 0.98 ? .red : .green)
                    Text(levelDescription).font(.caption.monospacedDigit())
                        .foregroundStyle(model.level >= 0.98 ? Color.red : Color.secondary)
                        .frame(width: 195, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button(action: model.record) {
                        Label(model.take == nil ? "Record" : "Record new take", systemImage: "record.circle")
                    }.buttonStyle(.borderedProminent).tint(.red)
                        .disabled(locked || !model.inputReady)
                    Button(action: model.stop) { Label("Stop", systemImage: "stop.fill") }
                        .disabled(!model.recording && !model.playing)
                    Spacer()
                    Text(model.recording ? "Recording · up to 2 minutes" : "No live monitoring")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        } label: { Label("Audio input", systemImage: "mic") }
    }

    private var levelDescription: String {
        guard model.inputReady else { return "Input off" }
        if model.level >= 0.98 { return "Clipping — reduce input gain" }
        if model.level < 0.002 { return "Input active · quiet" }
        return "Input active · \(Int((20 * log10(Double(model.level))).rounded())) dBFS"
    }

    private func takeSection(_ take: RecordedTake) -> some View {
        GroupBox {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(position(take.range.start)) to \(position(take.range.end))")
                        .font(.callout.weight(.medium))
                    Text("\(take.duration.formatted(.number.precision(.fractionLength(3)))) seconds · retained for this session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.play) { Label(model.playing ? "Stop playback" : "Play take", systemImage: model.playing ? "stop.fill" : "play.fill") }
                    .disabled(locked || (!model.beats.isEmpty && !validBeatMap))
                Button("Export WAV", action: model.exportWAV).disabled(locked)
            }.padding(8)
        } label: { Label("Current take", systemImage: "waveform") }
    }

    private var draftSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Picker("Solo part", selection: $model.trackIndex) {
                        Text("Select the monophonic solo part").tag(-1)
                        ForEach(model.tracks.indices, id: \.self) { index in
                            let track = model.tracks[index]
                            Text("\(index + 1). \(track.name.isEmpty ? "Untitled part" : track.name) · \(track.noteEvents.count) notes")
                                .tag(index).disabled(track.noteEvents.isEmpty)
                        }
                    }.onChange(of: model.trackIndex) { _, _ in model.changeTrack() }
                    Button("Analyze take", action: model.analyze)
                        .disabled(model.trackIndex < 0 || !model.tracks.indices.contains(model.trackIndex))
                }
                Text("Analysis is an estimate. Held notes, repeated pitches and rests can make the timing ambiguous.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 10) {
                    Text("Manual endpoints").font(.callout.weight(.medium))
                    Text("Start").foregroundStyle(.secondary)
                    RecordingNumberField("Start seconds", value: model.manualStart) {
                        model.manualStart = $0; model.approved = false
                    }.frame(width: 82).textFieldStyle(.roundedBorder)
                    Text("End").foregroundStyle(.secondary)
                    RecordingNumberField("End seconds", value: model.manualEnd) {
                        model.manualEnd = $0; model.approved = false
                    }.frame(width: 82).textFieldStyle(.roundedBorder)
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Create manual draft", action: model.manual)
                }
                Text("Manual timing spaces beats evenly between your endpoints. You can adjust every beat below.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).disabled(locked)
        } label: { Label("Create a draft", systemImage: "wand.and.stars") }
    }

    private var reviewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 0) {
                        HStack { Text("Measure").frame(width: 62); Text("Beat").frame(width: 42); Text("Recording seconds").frame(width: 142); Text("BPM").frame(width: 72) }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(model.beats.indices, id: \.self) { index in beatRow(index) }
                            }
                        }.frame(height: 215)
                    }
                    VStack(spacing: 8) {
                        RecordingBeatPreview(beats: model.playing ? model.beats : [], time: model.playbackTime)
                            .frame(minWidth: 230, minHeight: 160)
                        Text("Preview follows take playback")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(model.playbackTime.formatted(.number.precision(.fractionLength(3))) + " s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                Text(model.approved ? "Approved for export. Your score and performance audio have not been changed." : "Draft — listen and correct every beat before approving. Changes revoke approval.")
                    .font(.callout).foregroundStyle(model.approved ? Color.green : Color.secondary)
                HStack(spacing: 12) {
                    Button("Simplify within measures", action: model.simplify).disabled(!validBeatMap)
                    Button("Approve timing", action: model.approve).disabled(!validBeatMap)
                    Spacer()
                    Button("Export tempo CSV", action: model.exportCSV)
                        .buttonStyle(.borderedProminent).disabled(!model.approved || !validBeatMap)
                }.disabled(locked)
            }.padding(8)
        } label: { Label("Review beat timing", systemImage: "slider.horizontal.3") }
    }

    private func beatRow(_ index: Int) -> some View {
        let beat = model.beats[index]
        return HStack {
            Text("\(Int(floor(beat.quarter / 4)) + 1)").frame(width: 62)
            Text("\(Int(beat.quarter.truncatingRemainder(dividingBy: 4)) + 1)").frame(width: 42)
            RecordingNumberField("Recording seconds", value: beat.time) {
                model.editBeat(index: index, time: $0)
            }
                .textFieldStyle(.roundedBorder).frame(width: 142)
                .accessibilityLabel("\(position(beat.quarter)) recording seconds")
                .disabled(locked)
            Text(tempoLabel(index)).frame(width: 72)
        }.font(.callout.monospacedDigit())
    }

    private func tempoLabel(_ index: Int) -> String {
        guard index + 1 < model.beats.count else { return "End" }
        let interval = model.beats[index + 1].time - model.beats[index].time
        guard interval > 0, interval.isFinite else { return "—" }
        return (60 / interval).formatted(.number.precision(.fractionLength(1)))
    }

    private func position(_ quarter: Double) -> String {
        "measure \(Int(floor(quarter / 4)) + 1), beat \(Int(quarter.truncatingRemainder(dividingBy: 4)) + 1)"
    }
}

/// Owns the visible draft so partial input never silently retains a prior valid value.
private struct RecordingNumberField: View {
    let title: String
    let value: Double
    let integer: Bool
    let onEdit: (Double) -> Void
    @State private var text: String
    @State private var submitted: Double?
    @FocusState private var focused: Bool

    init(_ title: String, value: Double, integer: Bool = false, onEdit: @escaping (Double) -> Void) {
        self.title = title; self.value = value; self.integer = integer; self.onEdit = onEdit
        _text = State(initialValue: Self.display(value, integer: integer))
    }

    var body: some View {
        TextField(title, text: Binding(get: { text }, set: { raw in
            text = raw
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = integer ? Int(trimmed).map(Double.init) : Double(trimmed)
            let candidate: Double
            if integer {
                candidate = parsed.flatMap { $0 >= Double(Int.min) && $0 < Double(Int.max) ? $0 : nil } ?? 0
            } else { candidate = parsed ?? .nan }
            submitted = candidate
            onEdit(candidate)
        }))
        .focused($focused)
        .onChange(of: value) { _, updated in
            // Ignore the model echo of our edit, including NaN, so '1.' stays '1.'.
            if let submitted, Self.same(submitted, updated) { return }
            text = Self.display(updated, integer: integer)
            submitted = nil
        }
        .onChange(of: focused) { _, editing in
            if !editing && value.isFinite { text = Self.display(value, integer: integer) }
        }
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }
    private static func display(_ value: Double, integer: Bool) -> String {
        guard value.isFinite else { return "" }
        if integer { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Sampled only from the model's playback clock; rendering never advances time.
private struct RecordingBeatPreview: View {
    let beats: [BeatTime]
    let time: Double

    private func scoreQuarter(at time: Double) -> Double? {
        guard beats.count >= 2, beats.allSatisfy({ $0.time.isFinite && $0.quarter.isFinite }),
              let first = beats.first, let last = beats.last, time >= first.time, time < last.time else { return nil }
        for index in 1..<beats.count where beats[index].time <= beats[index - 1].time { return nil }
        for index in 0..<(beats.count - 1) {
            let a = beats[index], b = beats[index + 1]
            guard b.time > a.time else { continue }
            if time < b.time { return a.quarter + (time - a.time) / (b.time - a.time) * (b.quarter - a.quarter) }
        }
        return nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.055, green: 0.075, blue: 0.105))
            Canvas { context, size in
                let scale = min(size.width / 1.65, size.height / 0.95)
                func location(_ q: Double) -> CGPoint {
                    let point = ConductorGeometry.point(beat: Int(floor(q)) % 4, phase: q - floor(q))
                    return CGPoint(x: size.width / 2 + point.x * scale, y: size.height * 0.22 + point.y * scale)
                }
                guard let q = scoreQuarter(at: time) else { return }
                var trail = Path(), started = false
                for i in 0...24 {
                    guard let old = scoreQuarter(at: time - 0.24 + Double(i) * 0.01) else { continue }
                    if started { trail.addLine(to: location(old)) } else { trail.move(to: location(old)); started = true }
                }
                context.stroke(trail, with: .color(.cyan.opacity(0.4)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                let point = location(q)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(.cyan))
            }
            VStack {
                Text(scoreQuarter(at: time).map { "\(Int(floor($0 / 4)) + 1)" } ?? "—")
                    .font(.title2.monospacedDigit().weight(.medium)).foregroundStyle(.white)
                Spacer()
            }.padding(.top, 10)
        }.accessibilityLabel("Beat timing preview")
    }
}
