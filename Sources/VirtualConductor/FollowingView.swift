import SwiftUI
import ConductorCore

struct FollowingView: View {
    @ObservedObject var model: PerformanceModel
    @State private var values = FollowingConfiguration()
    @State private var tolerance = 10.0
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
            Text("Unaccompanied passages of at least one measure automatically follow freely. Existing cadenzas keep their pedal-controlled behavior and take priority.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Wait points").font(.headline)
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
            if let plan = try? model.followingPlan(configuration: values) {
                Text("\(plan.freePassages.count) unaccompanied passages detected for free following.").font(.caption)
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
