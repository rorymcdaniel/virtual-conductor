import SwiftUI

@main struct VirtualConductorApp: App {
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
                    if args.count >= 3, model.prepared == nil { model.load(midi:URL(fileURLWithPath:args[1]),wav:URL(fileURLWithPath:args[2])) }
                }
        }.defaultSize(width:1120,height:850)
    }
}
