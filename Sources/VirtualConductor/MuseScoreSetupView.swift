import SwiftUI

struct MuseScoreSetupView: View {
    @ObservedObject var link: MuseScoreLink
    var prepared: (RehearsalFiles) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rehearse with MuseScore").font(.title2)
            Text("Open your score in MuseScore and run the Virtual Conductor plugin. Keep its connection window open while you rehearse.")
            Button("Install / update MuseScore companion", action: link.install).disabled(link.busy)
            HStack {
                Text(link.sourceURL?.lastPathComponent ?? "No saved score selected").lineLimit(1)
                Spacer()
                Button("Choose saved score…", action: link.chooseScore).disabled(link.busy)
            }
            Text("Save changes in MuseScore before preparing. The app checks that the open score matches this file.").font(.caption).foregroundStyle(.secondary)
            Text(link.message).font(.callout).textSelection(.enabled)
            HStack {
                Button("Close") { dismiss() }.disabled(link.busy)
                Spacer()
                if link.busy { ProgressView().controlSize(.small) }
                Button("Prepare rehearsal") {
                    Task {
                        do { prepared(try await link.prepare()) }
                        catch { link.message = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(link.busy)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(link.busy)
    }
}
