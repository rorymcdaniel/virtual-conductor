import Foundation
import AVFoundation
import ConductorCore
@testable import VirtualConductor

@MainActor final class MuseScoreExportFixture {
    let root: URL
    let link: MuseScoreLink
    let source: URL
    let sourceData: Data
    let originalXML = "<?xml version=\"1.0\"?><score-partwise><!-- original --></score-partwise>\n"
    let previewXML = "<?xml version=\"1.0\"?><score-partwise><!-- changed timing --></score-partwise>\n"
    var snapshotRevision = "prepared-revision"
    var keepError: String?
    private(set) var requests: [[String: Any]] = []
    private var responder: Task<Void, Never>?
    private let savedSourcePath = UserDefaults.standard.object(forKey: "MuseScoreSourcePath")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("owner score.mscz")
        sourceData = Data("synthetic owner's native score, never rewritten".utf8)
        try sourceData.write(to: source)
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("<container><rootfiles><rootfile full-path=\"score.mscx\"/></rootfiles></container>".utf8)
            .write(to: archive.appendingPathComponent("META-INF/container.xml"))
        try Data("<museScore><Score><metaTag name=\"virtualConductorSignature\">prepared-revision</metaTag></Score></museScore>".utf8)
            .write(to: archive.appendingPathComponent("score.mscx"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = archive
        zip.arguments = ["-q", root.appendingPathComponent("verified.mscz").path, "META-INF/container.xml", "score.mscx"]
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw MusicalError("Could not make synthetic archive.") }
        for (name, tempo) in [("original", [UInt8(0x07), 0xa1, 0x20]), ("preview", [UInt8(0x0f), 0x42, 0x40])] {
            let track: [UInt8] = [0, 0xff, 0x51, 3] + tempo + [0, 0x90, 60, 80, 0x8f, 0, 0x80, 60, 0, 0, 0xff, 0x2f, 0]
            let header: [UInt8] = [0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0xe0, 0x4d, 0x54, 0x72, 0x6b, 0, 0, 0, UInt8(track.count)]
            try Data(header + track).write(to: root.appendingPathComponent("\(name).mid"))
        }
        try Data(originalXML.utf8).write(to: root.appendingPathComponent("original.musicxml"))
        try Data(previewXML.utf8).write(to: root.appendingPathComponent("preview.musicxml"))
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let audio = try AVAudioFile(forWriting: root.appendingPathComponent("audio.wav"), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80)!
        buffer.frameLength = 80
        buffer.floatChannelData![0].initialize(repeating: 0, count: 80)
        try audio.write(from: buffer)
        let executable = root.appendingPathComponent("mscore")
        try """
        #!/bin/sh
        set -eu
        root="$(dirname "$0")"
        if [ "$1" = "-j" ]; then
            out=$(/usr/bin/plutil -extract 0.out raw -o - "$2")
            /bin/cp "$root/verified.mscz" "$out"
            exit 0
        fi
        printf '%s\\n' "$1" "$3" >> "$root/exports.txt"
        variant=original
        case "$1" in */preview.mscz) variant=preview;; esac
        case "$3" in
            *.mid) /bin/cp "$root/$variant.mid" "$3";;
            *.wav) /bin/cp "$root/audio.wav" "$3";;
            *.musicxml)
                mode=$(cat "$root/xml-mode" 2>/dev/null || true)
                case "$mode" in
                    missing) exit 0;;
                    empty) : > "$3";;
                    malformed) printf '<score-partwise>' > "$3";;
                    unreadable) /bin/mkdir "$3";;
                    failed) echo 'synthetic MusicXML exporter failure' >&2; exit 1;;
                    *) /bin/cp "$root/$variant.musicxml" "$3";;
                esac;;
            *) exit 2;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        link = MuseScoreLink(root: root.appendingPathComponent("bridge"), executable: executable,
                             renderExtensionFolder: root.appendingPathComponent("extension"))
        link.sourceURL = source
    }

    func start() {
        responder = Task { [weak self] in
            var previousID = ""
            while !Task.isCancelled {
                guard let self else { return }
                let requestURL = link.root.appendingPathComponent("request.json")
                if let data = try? Data(contentsOf: requestURL),
                   let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = request["id"] as? String, id != previousID {
                    previousID = id
                    requests.append(request)
                    let keep = request["operation"] as? String == "keep"
                    var response: [String: Any] = ["id": id, "success": true, "name": "Synthetic", "revision": keep ? "kept-revision" : snapshotRevision]
                    if keep, let keepError { response["success"] = false; response["error"] = keepError }
                    try? JSONSerialization.data(withJSONObject: response).write(to: link.root.appendingPathComponent("response.json"), options: .atomic)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func close() {
        responder?.cancel()
        UserDefaults.standard.set(savedSourcePath, forKey: "MuseScoreSourcePath")
        try? FileManager.default.removeItem(at: root)
    }

    func makePreview() async throws -> RehearsalFiles {
        let midi = try MIDIFile(data: Data(contentsOf: link.rehearsal!.midi))
        let take = RecordedTake(samples: [0, 0, 0, 0], sampleRate: 1, range: PassageRange(start: 0, end: 4))
        return try await link.makePreview(beats: [BeatTime(quarter: 0, time: 0), BeatTime(quarter: 4, time: 4)], take: take, midi: midi)
    }

    func setXMLMode(_ mode: String) throws {
        try mode.write(to: root.appendingPathComponent("xml-mode"), atomically: true, encoding: .utf8)
    }

    func exportInputs() throws -> [String] {
        let lines = try String(contentsOf: root.appendingPathComponent("exports.txt"), encoding: .utf8).split(separator: "\n")
        return stride(from: 0, to: lines.count, by: 2).map { String(lines[$0]) }
    }
}
