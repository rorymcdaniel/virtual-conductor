import Foundation
import AppKit
import AVFoundation
import ConductorCore
import UniformTypeIdentifiers

struct RehearsalFiles {
    let score: URL
    let midi: URL
    let wav: URL
    let musicXML: URL
}
struct TempoPoint: Codable, Equatable {
    let quarter: Double
    let bpm: Double
}

/// Control-side file transport. Requests expire and are never retried implicitly.
@MainActor final class MuseScoreLink: ObservableObject {
    @Published var busy = false
    @Published var connected = false
    @Published var message = "Open your score in MuseScore, then run the Virtual Conductor plugin."
    @Published var name = "MuseScore"
    @Published var sourceURL: URL? {
        didSet { UserDefaults.standard.set(sourceURL?.path, forKey: "MuseScoreSourcePath") }
    }
    private(set) var rehearsal: RehearsalFiles?
    private(set) var preview: RehearsalFiles?
    private var revision = ""
    private var previewPoints: [TempoPoint] = []
    private var previewRange: PassageRange?
    let root: URL
    private let executable: URL
    private let renderExtensionFolder: URL
    init(root: URL? = nil,
         executable: URL = URL(fileURLWithPath: "/Applications/MuseScore 4.app/Contents/MacOS/mscore"),
         renderExtensionFolder: URL? = nil) {
        self.executable = executable
        self.renderExtensionFolder = renderExtensionFolder ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MuseScore/MuseScore4/extensions/virtual-conductor-render")
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MuseScore4/VirtualConductor", isDirectory: true)
        if let path = UserDefaults.standard.string(forKey: "MuseScoreSourcePath") { sourceURL = URL(fileURLWithPath: path) }
    }
    private var resources: URL { Bundle.module.url(forResource: "MuseScore", withExtension: nil)! }
    func install() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let plugins = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/MuseScore4/Plugins/VirtualConductor")
            try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
            let quoted = String(data: try JSONEncoder().encode(root.path), encoding: .utf8)!
            let qml = try String(contentsOf: resources.appendingPathComponent("VirtualConductor.qml"), encoding: .utf8)
                .replacingOccurrences(of: "__BRIDGE_PATH__", with: quoted)
            try qml.write(to: plugins.appendingPathComponent("VirtualConductor.qml"), atomically: true, encoding: .utf8)
            try Data(contentsOf: resources.appendingPathComponent("Tempo.js")).write(to: plugins.appendingPathComponent("Tempo.js"), options: .atomic)
            message = "In MuseScore: Plugins → Manage plugins → Reload plugins. Enable Virtual Conductor, open your score, then run Plugins → Virtual Conductor. Leave its window open."
        } catch { message = error.localizedDescription }
    }
    private func request(_ fields: [String: Any]) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        var body = fields; body["id"] = id; body["expires"] = Date().addingTimeInterval(30).timeIntervalSince1970 * 1000
        let requestURL = root.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: body).write(to: requestURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: requestURL) }
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(250))
            if let data = try? Data(contentsOf: root.appendingPathComponent("response.json")),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["id"] as? String == id {
                guard result["success"] as? Bool == true else { throw MusicalError(result["error"] as? String ?? "MuseScore could not finish the request.") }
                return result
            }
        }
        throw MusicalError("MuseScore did not reply. Open the Virtual Conductor plugin in MuseScore and try again. If Keep it timed out, check MuseScore before retrying.")
    }
    private func directory() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func chooseScore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "mscz") ?? .data]
        panel.message = "Save your open MuseScore score, then select that file."
        if panel.runModal() == .OK { sourceURL = panel.url }
    }
    func prepare() async throws -> RehearsalFiles {
        guard !busy, let sourceURL else { throw MusicalError("Choose your saved MuseScore score first.") }
        busy = true; defer { busy = false }
        message = "Copying the open score and preparing accompaniment…"
        let folder = try directory(), score = folder.appendingPathComponent("rehearsal.mscz")
        let response = try await request(["operation": "snapshot"])
        try Data(contentsOf: sourceURL).write(to: score, options: .atomic)
        let verified = folder.appendingPathComponent("verified.mscz")
        try await transform(source: score, destination: verified, body: "api.engraving.curScore.setMetaTag('virtualConductorSignature', signature(api.engraving.curScore));")
        let savedRevision = try await Self.readSignature(verified)
        guard savedRevision == response["revision"] as? String else {
            throw MusicalError("The saved file differs from the open score. Save in MuseScore, select the same file, and prepare again.")
        }
        let files = try await export(score: score)
        rehearsal = files; preview = nil; revision = response["revision"] as? String ?? ""
        name = response["name"] as? String ?? "MuseScore"; connected = true
        message = "Rehearsal ready. Record your solo, then hear the accompaniment follow it."
        return files
    }
    static func points(beats: [BeatTime], range: PassageRange, midi: MIDIFile, duration: Double) throws -> [TempoPoint] {
        try Interpretation.validate(beats, duration: duration)
        guard beats.first?.quarter == range.start, beats.last?.quarter == range.end else { throw MusicalError("Timing does not match the recorded passage.") }
        var result = zip(beats, beats.dropFirst()).map { a, b in TempoPoint(quarter: a.quarter, bpm: (60 * (b.quarter-a.quarter) / (b.time-a.time) * 1000).rounded()/1000) }
        if range.end < midi.endQuarter { result.append(TempoPoint(quarter: range.end, bpm: midi.tempo(atSeconds: midi.seconds(atQuarter: range.end)))) }
        guard result.allSatisfy({ $0.bpm.isFinite && (10...600).contains($0.bpm) }) else { throw MusicalError("Timing must stay between 10 and 600 BPM. Adjust the draft and listen again.") }
        return result
    }
    func makePreview(beats: [BeatTime], take: RecordedTake, midi: MIDIFile) async throws -> RehearsalFiles {
        guard !busy, let rehearsal else { throw MusicalError("Prepare a MuseScore rehearsal first.") }
        let points = try Self.points(beats: beats, range: take.range, midi: midi, duration: take.duration)
        if let preview, points == previewPoints, previewRange?.start == take.range.start, previewRange?.end == take.range.end { return preview }
        busy = true; defer { busy = false }
        preview = nil; message = "Rendering accompaniment with your timing…"
        let folder = try directory(), score = folder.appendingPathComponent("preview.mscz")
        let json = String(data: try JSONSerialization.data(withJSONObject: payload(points: points, range: take.range)), encoding: .utf8)!
        try await transform(source: rehearsal.score, destination: score, body: "apply(api.engraving, api.engraving.curScore, \(json));")
        let files = try await export(score: score)
        let rendered = try MIDIFile(data: Data(contentsOf: files.midi))
        guard rendered.tracks.map(\.noteEvents) == midi.tracks.map(\.noteEvents) else {
            throw MusicalError("The rendered score changed the reference notes. This draft was not kept.")
        }
        for point in points {
            let actual = rendered.tempo(atSeconds: rendered.seconds(atQuarter: point.quarter))
            guard abs(actual-point.bpm) < 0.02 else { throw MusicalError("MuseScore did not render the requested tempo. This draft was not kept.") }
        }
        preview = files; previewPoints = points; previewRange = take.range
        message = "Listen to this accompaniment. Keep it if it follows your playing."
        return files
    }
    func disconnect() { connected = false; rehearsal = nil; invalidatePreview() }
    func invalidatePreview() { preview = nil; previewPoints = []; previewRange = nil }
    private func payload(points: [TempoPoint], range: PassageRange) throws -> [String: Any] {
        ["start":range.start,"end":range.end,"tempos":try JSONSerialization.jsonObject(with: JSONEncoder().encode(points))]
    }
    func keep() async throws -> RehearsalFiles {
        guard !busy, let preview, let range = previewRange else { throw MusicalError("Hear the accompaniment before keeping it.") }
        busy = true; defer { busy = false }
        var body = try payload(points: previewPoints, range: range)
        body["operation"] = "keep"; body["revision"] = revision
        let response = try await request(body)
        revision = response["revision"] as? String ?? ""
        rehearsal = preview; invalidatePreview()
        message = "Kept in MuseScore. Save your score there when ready. Your take is still here."
        return preview
    }
    private nonisolated static func readSignature(_ score: URL) async throws -> String {
        try await Task.detached {
            func entry(_ name: String) throws -> Data {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-p", score.path, name]; process.standardOutput = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw MusicalError("Could not inspect the saved score.") }
                return data
            }
            let reader = ScoreSignatureReader(), container = XMLParser(data: try entry("META-INF/container.xml"))
            container.delegate = reader
            guard container.parse(), let mainScore = reader.rootFile else { throw MusicalError("The score archive has no main score.") }
            let parser = XMLParser(data: try entry(mainScore)); parser.delegate = reader
            guard parser.parse(), let value = reader.value else { throw MusicalError("MuseScore did not return a score fingerprint.") }
            return value
        }.value
    }
    private func transform(source: URL, destination: URL, body: String) async throws {
        let extensionFolder = renderExtensionFolder
        try FileManager.default.createDirectory(at: extensionFolder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["uri":"musescore://extensions/virtualconductor/render", "type":"composite", "title":"Virtual Conductor render", "ui_context":"Any", "actions":[["code":"render", "type":"macros", "path":"render.js", "show_on_appmenu":false]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extensionFolder.appendingPathComponent("manifest.json"), options: .atomic)
        let script = try String(contentsOf: resources.appendingPathComponent("Tempo.js"), encoding: .utf8) + "\nfunction main() { \(body) }\n"
        try script.write(to: extensionFolder.appendingPathComponent("render.js"), atomically: true, encoding: .utf8)
        let job = destination.deletingLastPathComponent().appendingPathComponent("job.json")
        try JSONSerialization.data(withJSONObject: [["in":source.path,"out":destination.path]]).write(to: job, options: .atomic)
        try await process(["-j",job.path,"--extension","musescore://extensions/virtualconductor/render?action=render"], log: destination.deletingPathExtension().appendingPathExtension("render.log"))
    }
    private func export(score: URL) async throws -> RehearsalFiles {
        let midi = score.deletingPathExtension().appendingPathExtension("mid"), wav = score.deletingPathExtension().appendingPathExtension("wav")
        let musicXML = score.deletingPathExtension().appendingPathExtension("musicxml")
        try await process([score.path,"-o",midi.path], log: score.deletingPathExtension().appendingPathExtension("midi.log"))
        try await process([score.path,"-o",wav.path], log: score.deletingPathExtension().appendingPathExtension("wav.log"))
        let musicXMLLog = score.deletingPathExtension().appendingPathExtension("musicxml.log")
        do {
            try await process([score.path,"-o",musicXML.path], log: musicXMLLog)
            let data = try Data(contentsOf: musicXML)
            guard !data.isEmpty else { throw MusicalError("The XML document is empty.") }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw MusicalError(parser.parserError?.localizedDescription ?? "The XML document is malformed.") }
        } catch {
            throw MusicalError("MuseScore MusicXML export failed. Your previous rehearsal is retained. Output: \(musicXML.path). Details: \(musicXMLLog.path). \(error.localizedDescription)")
        }
        _ = try MIDIFile(data: Data(contentsOf: midi))
        let file = try AVAudioFile(forReading: wav)
        guard file.length > 0 else { throw MusicalError("MuseScore exported empty audio. Your previous rehearsal is retained.") }
        return RehearsalFiles(score: score, midi: midi, wav: wav, musicXML: musicXML)
    }
    private func process(_ arguments: [String], log: URL) async throws {
        let executable = executable
        try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
            process.standardOutput = output; process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(180)
            while process.isRunning {
                if Date() > deadline || Task.isCancelled { process.terminate(); throw MusicalError("MuseScore export stopped. The previous rehearsal is retained.") }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard process.terminationStatus == 0 else { throw MusicalError("MuseScore export failed. Details: \(log.path)") }
        }.value
    }
}

private final class ScoreSignatureReader: NSObject, XMLParserDelegate {
    var value: String?
    var rootFile: String?
    private var reading = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "rootfile", let path = attributeDict["full-path"], path.hasSuffix(".mscx"), rootFile == nil { rootFile = path }
        if elementName == "metaTag", attributeDict["name"] == "virtualConductorSignature" { reading = true; value = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { value? += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == "metaTag" { reading = false } }
}
