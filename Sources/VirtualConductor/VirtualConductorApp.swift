import SwiftUI

@main struct VirtualConductorApp: App {
    init() {
        // The installed SDK only accepts deployment targets through 27.0.
        // Enforce the supported runtime for direct executable launches as well.
        guard #available(macOS 27.2, *) else {
            fatalError("Virtual Conductor requires macOS 27.2 or later.")
        }
    }
    @StateObject private var model = PerformanceModel()
    @State private var keys: PerformanceKeys?
    var body: some Scene {
        Window("Virtual Conductor", id:"performance") {
            MainView(model:model)
                .frame(minWidth:960,minHeight:720)
                .preferredColorScheme(.dark)
                .onAppear {
                    if keys == nil { keys = PerformanceKeys(model:model) }
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
                    let args = CommandLine.arguments
                    if args.count >= 3, model.prepared == nil {
                        let musicXML = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil
                        model.load(midi: URL(fileURLWithPath: args[1]), wav: URL(fileURLWithPath: args[2]),
                                   musicXML: musicXML, scoreIdentity: musicXML)
                    }
                }
        }.defaultSize(width:1120,height:850)
    }
}
