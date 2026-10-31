import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ConductorCore

@MainActor
struct MainView: View {
    @ObservedObject var model: PerformanceModel
    @State private var museScoreOpen = false
    private let accent = Color(red: 0.63, green: 0.90, blue: 0.83)
    private var editable: Bool { model.prepared != nil && [.ready, .paused, .waiting, .finished, .interrupted].contains(model.state) }
    private var outputs: [AudioDevice] { model.devices.filter(\.output) }
    private var playTitle: String {
        switch model.state {
        case .running: return "Pause"
        case .paused: return "Resume"
        case .finished: return "Play again"
        case .waiting: return "Awaiting pedal"
        case .starting: return "Starting…"
        default: return "Start"
        }
    }
    private var stateTitle: String {
        switch model.state {
        case .empty: return "Choose exports"
        case .loading: return "Preparing audio"
        case .ready: return "Ready"
        case .starting: return "Starting"
        case .running: return "Performing"
        case .paused: return "Paused"
        case .waiting: return "Cadenza · awaiting pedal"
        case .finished: return "Finished"
        case .interrupted: return "Reconnect output"
        case .error: return "Unable to load"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.clean { header }
            ZStack(alignment: .bottomTrailing) {
                ConductorSurface(model: model)
                if model.clean {
                    Button { model.clean = false } label: {
                        Text("H · Show controls").font(.caption).foregroundStyle(.white.opacity(0.50))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.black.opacity(0.25), in: Capsule())
                    }.buttonStyle(.plain).padding(20).help("Show setup controls")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 240)
            if !model.clean { controls }
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .preferredColorScheme(.dark)
        .tint(accent)
        .frame(minWidth: 980, minHeight: 640)
        .onChange(of: museScoreOpen) { _, open in model.filePanelOpen = open }
        .sheet(isPresented: $museScoreOpen) {
            MuseScoreSetupView(link: model.museScore) { files in
                museScoreOpen = false; model.load(midi: files.midi, wav: files.wav, musicXML: files.musicXML, scoreIdentity: model.museScore.sourceURL, linked: true)
            }
        }
        .sheet(isPresented: $model.importOpen) { ImportExportsView(model: model) }
        .sheet(isPresented: $model.editorOpen) { CadenzaEditorView(model: model) }
        .sheet(isPresented: $model.utilityOpen, onDismiss: model.closeRecording) {
            RecordingView(model: model.recording, onClose: model.closeRecording)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VIRTUAL CONDUCTOR").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2.5).foregroundStyle(accent)
                Text(model.museScore.connected ? model.museScore.name : (model.midiURL?.deletingPathExtension().lastPathComponent ?? "Your rehearsal, your entrance"))
                    .font(.system(size: 21, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(model.outputMissing || model.state == .error ? Color.orange : accent).frame(width: 6, height: 6)
                Text(stateTitle).font(.callout.weight(.medium))
            }.padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.055), in: Capsule())
            Button { model.clean = true } label: { Image(systemName: "rectangle.compress.vertical") }
                .help("Hide controls · H")
            Button {
                model.clean = true
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button(action: model.toggle) {
                    Label(playTitle, systemImage: model.state == .running ? "pause.fill" : "play.fill")
                        .frame(minWidth: 94).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.prepared == nil || model.outputMissing || ![.ready, .running, .paused, .finished].contains(model.state))
                Button("Reset", action: model.reset).disabled(model.prepared == nil || [.loading, .starting].contains(model.state))
                Divider().frame(height: 22)
                Stepper(value: $model.preparation, in: 0...99) {
                    Text("Preparation: \(model.preparation) \(model.preparation == 1 ? "measure" : "measures")").monospacedDigit()
                }
                .fixedSize()
                .disabled(model.locked || [.paused, .waiting].contains(model.state))
                .onChange(of: model.preparation) { _, _ in model.rebuild() }
                Spacer()
                Toggle("Clicks", isOn: $model.clicks).toggleStyle(.checkbox)
                Toggle("Guide", isOn: $model.guide).toggleStyle(.checkbox)
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1).frame(width: 110).accessibilityLabel("Playback volume")
            }
            HStack(spacing: 10) {
                Picker("Audio output", selection: $model.outputID) {
                    if !outputs.contains(where: { $0.id == model.outputID }) {
                        Text(model.outputID == 0 ? "Choose output" : "Selected output unavailable").tag(model.outputID)
                    }
                    ForEach(outputs) { device in Text(device.name).tag(device.id) }
                }
                .frame(maxWidth: 380)
                .disabled(model.locked)
                .onChange(of: model.outputID) { _, _ in model.chooseOutput() }
                Button("Reconnect", action: model.chooseOutput)
                    .disabled(model.locked || !outputs.contains(where: { $0.id == model.outputID }))
                    .help("Explicitly reconnect the selected output after an interruption")
                Button("Test output", action: model.testOutput).disabled(model.locked || model.outputMissing)
                Spacer()
                Text("Space · play/pause    ArrowRight · cadenza entrance")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    Picker("Solo staff", selection: Binding(get: { model.longRestSetup.selectedStaffID }, set: { model.selectLongRestStaff($0) })) {
                        Text("Choose solo staff").tag(Optional<MusicXMLStaffID>.none)
                        ForEach(model.longRestSetup.staves, id: \.id) { staff in
                            Text(staff.displayName).tag(Optional(staff.id))
                        }
                    }.frame(maxWidth: 380).disabled(model.longRestSetup.staves.isEmpty || model.locked)
                    Stepper(value: Binding(get: { model.longRestSetup.threshold }, set: { model.setLongRestThreshold($0) }), in: 1...Int.max) {
                        Text("Long rest: at least \(model.longRestSetup.threshold) full measures").monospacedDigit()
                    }.fixedSize().disabled(model.locked)
                    Spacer()
                }
                Text(model.longRestSetup.availability).font(.caption).foregroundStyle(.secondary)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 10) {
                Button("MuseScore rehearsal…") { model.pause(); museScoreOpen = true }.disabled(model.locked)
                Button("Load new exports…") { model.pause(); model.importOpen = true }
                    .disabled([.loading, .starting].contains(model.state))
                Button("Reread exports", action: model.reload)
                    .disabled(model.midiURL == nil || model.wavURL == nil || [.loading, .starting].contains(model.state))
                Spacer()
                Button("Cadenza passages…") { model.editorOpen = true }.disabled(!editable)
                Button("Import browser settings…", action: model.importSettings).disabled(!editable)
                Button("Record interpretation…", action: model.openRecording)
                    .disabled(model.prepared == nil || [.loading, .starting].contains(model.state))
            }
            if let midi = model.midiURL, let wav = model.wavURL {
                HStack {
                    Text("MIDI: \(midi.lastPathComponent) · WAV: \(wav.lastPathComponent)")
                        .lineLimit(1).truncationMode(.middle).help("\(midi.path)\n\(wav.path)")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        if let timing = model.prepared?.timing { Text(String(format:"♩ = %.1f",timing.position(model.elapsed()).bpm)).monospacedDigit() }
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                Text(model.message).font(.caption).foregroundStyle(model.outputMissing || model.state == .error ? Color.orange : Color.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !model.passages.isEmpty {
                    Text("\(model.passages.count) cadenza \(model.passages.count == 1 ? "passage" : "passages")")
                        .font(.caption).foregroundStyle(accent).fixedSize()
                }
            }.frame(minHeight: 25, alignment: .top)
        }
        .disabled(model.shortcutsBlocked)
        .controlSize(.regular)
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 18)
        .background(Color(red: 0.07, green: 0.09, blue: 0.10))
    }
}

@MainActor
private struct ImportExportsView: View {
    @ObservedObject var model: PerformanceModel
    @State private var midi: URL?
    @State private var wav: URL?
    @State private var musicXML: URL?
    private var validPair: Bool {
        guard let midi, let wav else { return false }
        return ["mid", "midi"].contains(midi.pathExtension.lowercased()) && wav.pathExtension.lowercased() == "wav"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Load matching exports").font(.title2.weight(.semibold))
            Text("Choose the MIDI tempo map and its WAV accompaniment from the same score export.")
                .foregroundStyle(.secondary)
            fileRow("MIDI timing", url: midi) { chooseMIDI() }
            fileRow("WAV accompaniment", url: wav) { chooseWAV() }
            fileRow("MusicXML score (optional, for long-rest cues)", url: musicXML) { chooseMusicXML() }
            if musicXML != nil { Button("Remove MusicXML") { musicXML = nil } }
            Text("MusicXML must come from the same score snapshot as the MIDI and WAV. Without it, accompaniment still plays.").font(.caption).foregroundStyle(.secondary)
            Text(model.message).font(.caption).foregroundStyle(model.state == .error ? Color.orange : Color.secondary)
                .textSelection(.enabled).frame(minHeight: 36, alignment: .topLeading)
            HStack {
                Button("Cancel") { model.importOpen = false }.keyboardShortcut(.cancelAction).disabled(model.state == .loading)
                Spacer()
                if model.state == .loading { ProgressView().controlSize(.small) }
                Button("Load") { if let midi, let wav { model.load(midi: midi, wav: wav, musicXML: musicXML, scoreIdentity: musicXML) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!validPair || model.state == .loading)
            }
        }
        .padding(26).frame(width: 570)
        .interactiveDismissDisabled(model.state == .loading)
        .onAppear { midi = model.midiURL; wav = model.wavURL }
    }
    private func fileRow(_ title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(url?.lastPathComponent ?? "No file selected").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(url?.path ?? "")
            }
            Spacer()
            Button("Choose…", action: action).disabled(model.state == .loading)
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func chooseMIDI() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        // Installed music apps can register conflicting MIDI content types.
        // The import form validates the extension and the reader validates the bytes.
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data, UTType(filenameExtension: "midi") ?? .data]
        panel.prompt = "Choose MIDI"
        if panel.runModal() == .OK { midi = panel.url }
    }
    private func chooseMusicXML() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml") ?? .xml, .xml]
        panel.prompt = "Choose matching MusicXML"
        if panel.runModal() == .OK { musicXML = panel.url }
    }
    private func chooseWAV() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]; panel.prompt = "Choose WAV"
        if panel.runModal() == .OK { wav = panel.url }
    }
}

@MainActor
private struct CadenzaEditorView: View {
    private struct Draft: Identifiable {
        let id = UUID()
        var startMeasure = "", startBeat = "", returnMeasure = "", returnBeat = ""
        init() {}
        init(_ passage: CadenzaPassage) {
            startMeasure = String(passage.startMeasure); startBeat = String(passage.startBeat)
            returnMeasure = String(passage.returnMeasure); returnBeat = String(passage.returnBeat)
        }
        func passage(index: Int) throws -> CadenzaPassage {
            guard let sm = Int(startMeasure), let sb = Int(startBeat), let rm = Int(returnMeasure), let rb = Int(returnBeat) else {
                throw MusicalError("Passage \(index + 1): choose whole measure and beat numbers.")
            }
            return CadenzaPassage(startMeasure: sm, startBeat: sb, returnMeasure: rm, returnBeat: rb)
        }
    }
    @ObservedObject var model: PerformanceModel
    @State private var draft: [Draft] = []
    @State private var error = ""
    @State private var checking = false
    @State private var validationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cadenza passages").font(.title2.weight(.semibold))
            Text("Stop at the start beat. Press ArrowRight to resume at the return beat, with no count-in. Measures begin at 1; beats run from 1 to 4.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if draft.isEmpty { Text("No passages. Saving this list removes all cadenza stops.").foregroundStyle(.secondary).padding(.vertical, 16) }
                    ForEach($draft) { $row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Start").font(.caption).foregroundStyle(.secondary)
                                HStack { field("Measure", text: $row.startMeasure); field("Beat", text: $row.startBeat) }
                            }
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 18)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Return").font(.caption).foregroundStyle(.secondary)
                                HStack { field("Measure", text: $row.returnMeasure); field("Beat", text: $row.returnBeat) }
                            }
                            Spacer()
                            Button(role: .destructive) { draft.removeAll { $0.id == row.id } } label: { Image(systemName: "trash") }
                                .help("Remove passage").padding(.top, 18)
                        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.disabled(checking)
            }.frame(minHeight: 100, maxHeight: 320)
            Button("Add passage") { draft.append(Draft()) }.disabled(checking)
            Text(error).font(.caption).foregroundStyle(.orange).frame(minHeight: 28, alignment: .topLeading)
            HStack {
                Button("Cancel") { validationTask?.cancel(); model.editorOpen = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if checking { ProgressView().controlSize(.small); Text("Checking accompaniment…").font(.caption).foregroundStyle(.secondary) }
                Button("Save passages", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(checking)
            }
        }
        .padding(26).frame(width: 620)
        .onAppear { draft = model.passages.map(Draft.init) }
        .onDisappear { validationTask?.cancel() }
    }
    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(width: prompt == "Measure" ? 86 : 62)
            .accessibilityLabel(prompt)
    }
    private func save() {
        error = ""
        do {
            let values = try draft.enumerated().map { try $0.element.passage(index: $0.offset) }
            let compiled = try model.savePassages(values)
            guard let prepared = model.prepared else { return }
            checking = true
            validationTask = Task {
                let sounding = await Task.detached(priority: .userInitiated) { prepared.sounding(compiled) }.value
                guard !Task.isCancelled else { return }
                checking = false
                if !sounding.isEmpty {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Are you sure?"
                    let ranges = sounding.map { "Measure \($0.passage.startMeasure), beat \($0.passage.startBeat) → measure \($0.passage.returnMeasure), beat \($0.passage.returnBeat)" }.joined(separator: "\n")
                    alert.informativeText = "Orchestral accompaniment is detected in the measures designated as the cadenza.\n\n\(ranges)\n\nSaving will skip this audio. Quiet noise or reverberation may also trigger this sound-level check. Cancel to revise the boundaries, or save anyway."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Save anyway")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                }
                do { try model.commitPassages(values) }
                catch { self.error = error.localizedDescription; model.message = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription; model.message = error.localizedDescription }
    }
}
