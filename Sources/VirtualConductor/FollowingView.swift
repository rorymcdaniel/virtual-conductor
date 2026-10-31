import SwiftUI
import ConductorCore

struct FollowingView: View {
    @ObservedObject var model: PerformanceModel
    @State private var values = FollowingConfiguration()
    @State private var tolerance = 10.0
    @State private var editingFree = true
    @State private var startMeasure = "1"
    @State private var startBeat = "1"
    @State private var returnMeasure = "2"
    @State private var returnBeat = "1"
    @State private var measure = 1
    @State private var beat = 1.0
    @State private var error = ""
    @State private var inputID: UInt32 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Follow the soloist").font(.title2.bold())
            Toggle("Listen and follow during playback", isOn: $values.enabled)
            Text("Use headphones, including open-back headphones with modest leakage. The solo instrument should be prominent at the microphone.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Solo staff", selection: $values.solo) {
                Text("Choose solo staff").tag(Optional<MusicXMLStaffID>.none)
                ForEach(model.longRestSetup.staves, id: \.id) { staff in Text(staff.displayName).tag(Optional(staff.id)) }
            }.disabled(model.longRestSetup.staves.isEmpty)
            if model.longRestSetup.staves.isEmpty {
                Text(model.longRestSetup.availability.replacingOccurrences(of: "Long-rest cues", with: "Live following"))
                    .font(.callout).foregroundStyle(.orange)
            }
            Picker("Microphone", selection: $inputID) {
                if !model.devices.contains(where: { $0.input && $0.id == inputID }) {
                    Text("Choose an available input").tag(inputID)
                }
                ForEach(model.devices.filter(\.input)) { device in Text(device.name).tag(device.id) }
            }
            Stepper("Global tempo tolerance: ±\(Int(tolerance))%", value: $tolerance, in: 0...75, step: 1)
            Text("Playback follows within this tolerance unless you mark a free passage or a wait. Pedal-controlled cadenzas take priority.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Edit", selection: $editingFree) {
                Text("Free passages").tag(true)
                Text("Wait points").tag(false)
            }.pickerStyle(.segmented)
            if editingFree {
                freeEditor
            } else {
                Text("Choose a solo note entrance. Its concert pitch comes from MusicXML. Fractional beats are supported, such as 2.5 for an eighth-note entrance.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Measure")
                    TextField("Measure", value: $measure, format: .number).frame(width: 70)
                    Text("Beat")
                    TextField("Beat", value: $beat, format: .number).frame(width: 70)
                    Button("Add wait") {
                        var proposed = values
                        proposed.waits.append(WaitPoint(measure: measure, beat: beat))
                        do {
                            _ = try model.followingPlan(configuration: proposed)
                            proposed.waits.sort { $0.quarter < $1.quarter }
                            values = proposed; error = ""
                        } catch { self.error = error.localizedDescription }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if values.waits.isEmpty { Text("No explicit wait points.").foregroundStyle(.secondary) }
                        ForEach(Array(values.waits.enumerated()), id: \.offset) { index, wait in
                            HStack {
                                Text("Measure \(wait.measure), beat \(wait.beat.formatted())")
                                if let plan = try? model.followingPlan(configuration: values),
                                   let note = plan.notes.first(where: { abs($0.startQuarter - wait.quarter) < 1e-7 }) {
                                    Text("· \(pitchName(note.pitch)) concert").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove") { values.waits.remove(at: index) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 120)
            }
            Text(error).font(.caption).foregroundStyle(.orange).frame(minHeight: 30)
            HStack {
                Button("Cancel") { model.followingOpen = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save and reset") {
                    do { try model.saveFollowing(values, tolerance: tolerance); model.following.inputID = inputID }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
            .onAppear { values = model.following.configuration; tolerance = model.following.tolerance; inputID = model.following.inputID }
    }
    private var freeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mark where you want to play freely while the orchestra rests. At Return, bounded playback resumes. Fractional beats are supported.")
                .font(.callout)
            Grid(alignment: .leading) {
                GridRow { Text(""); Text("Measure"); Text("Beat") }
                GridRow { Text("Start"); TextField("Start measure", text: $startMeasure); TextField("Start beat", text: $startBeat) }
                GridRow { Text("Return"); TextField("Return measure", text: $returnMeasure); TextField("Return beat", text: $returnBeat) }
            }.frame(maxWidth: 320)
            Button("Add free passage") {
                do {
                    let start = try location(startMeasure, startBeat)
                    let end = try location(returnMeasure, returnBeat)
                    var proposed = values
                    proposed.freePassages.append(PassageRange(start: start, end: end))
                    _ = try model.followingPlan(configuration: proposed)
                    proposed.freePassages.sort { $0.start < $1.start }
                    values = proposed
                    error = ""
                } catch { self.error = error.localizedDescription }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    if values.freePassages.isEmpty { Text("No free passages.").foregroundStyle(.secondary) }
                    ForEach(Array(values.freePassages.enumerated()), id: \.offset) { index, passage in
                        HStack {
                            Text("\(label(passage.start)) → \(label(passage.end))")
                            Spacer()
                            Button("Remove") { values.freePassages.remove(at: index) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 84)
        }
    }

    private func location(_ measure: String, _ beat: String) throws -> Double {
        guard let m = Int(measure), m >= 1, let b = Double(beat), b >= 1, b < 5 else {
            throw MusicalError("Enter a positive measure and a beat from 1 up to, but below, 5.")
        }
        return WaitPoint(measure: m, beat: b).quarter
    }

    private func label(_ quarter: Double) -> String {
        "Measure \(Int(quarter / 4) + 1), beat \((quarter.truncatingRemainder(dividingBy: 4) + 1).formatted())"
    }

    private func pitchName(_ pitch: Int) -> String {
        ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][pitch % 12] + String(pitch / 12 - 1)
    }
}

struct FollowingBanner: View {
    @ObservedObject var following: LiveFollowing
    var body: some View {
        if following.active {
            VStack(spacing: 5) {
                Label(following.status.rawValue, systemImage: icon)
                    .font(.system(size: following.status == .following ? 20 : 30, weight: .bold))
                Text(following.detail).font(.callout)
                ProgressView(value: min(1, Double(following.level) * 5)).frame(width: 160)
                    .accessibilityLabel("Microphone level")
            }
            .foregroundStyle(following.status == .lost ? Color.white : Color.black)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(following.status == .lost ? Color.red : following.status == .following ? Color.mint.opacity(0.85) : Color.yellow,
                        in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 18).allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
    private var icon: String {
        switch following.status {
        case .lost: "exclamationmark.triangle.fill"
        case .waiting: "pause.circle.fill"
        case .cadenza: "pedal.brake.fill"
        default: "waveform"
        }
    }
}
