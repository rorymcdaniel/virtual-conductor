import SwiftUI
import AppKit
import QuartzCore
import ConductorCore

struct ConductorSurface: NSViewRepresentable {
    var model: PerformanceModel
    func makeNSView(context: Context) -> ConductorDrawingView { let view = ConductorDrawingView(); view.model = model; return view }
    func updateNSView(_ view: ConductorDrawingView, context: Context) { view.model = model; view.needsDisplay = true }
}
@MainActor final class ConductorDrawingView: NSView {
    weak var model: PerformanceModel?
    private var link: CADisplayLink?
    private var displayHost = 0.0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); link?.invalidate(); link = nil
        if window != nil { let link = displayLink(target:self,selector:#selector(refresh(_:))); link.add(to:.main,forMode:.common); self.link = link }
    }
    @objc private func refresh(_ link: CADisplayLink) {
        // CADisplayLink timestamps and mach host seconds share uptime origin.
        displayHost = PerformanceAudio.hostSeconds + max(0,link.targetTimestamp-CACurrentMediaTime())
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let snapshot = model.snapshot(displayHost: displayHost > 0 ? displayHost : PerformanceAudio.hostSeconds)
        let p = snapshot.timing?.position(snapshot.time)
        let w = bounds.width, h = bounds.height
        let top = max(95,h*0.23), bottom = max(28,h*0.08), available = max(80,h-top-bottom)
        let scale = min(w*(model.clean ? 0.86 : 0.72)/1.32, available/0.661)
        let baseline = top+(available+0.66*scale)/2
        func xy(_ point: CGPoint) -> CGPoint { CGPoint(x:w/2+point.x*scale,y:baseline+(point.y-0.60)*scale) }
        func dot(_ point: CGPoint, radius:CGFloat,color:NSColor) { color.setFill(); NSBezierPath(ovalIn:NSRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)).fill() }
        func text(_ value:String,y:CGFloat,size:CGFloat,color:NSColor) {
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:size,weight:.light),.foregroundColor:color]
            let string = NSAttributedString(string:value,attributes:attributes)
            string.draw(at:CGPoint(x:(w-string.size().width)/2,y:y))
        }
        let active = [.running,.paused,.waiting,.finished,.interrupted].contains(snapshot.state)
        text(active ? p?.measure.map(String.init) ?? "—" : "—",y:4,size:min(72,h*0.17),color:.white)
        let status: String
        if snapshot.state == .running { status = p?.leadIn == true ? "Preparatory gesture" : p?.preparing == true ? "Preparation" : p?.ended == true ? "Finishing audio" : "Performing" }
        else { status = snapshot.state.rawValue.capitalized }
        text(status,y:min(82,h*0.20),size:14,color:.secondaryLabelColor)
        if snapshot.state == .waiting {
            text("CADENZA",y:h*0.46,size:min(60,w/9),color:.white)
            text("Awaiting pedal · →",y:h*0.46+74,size:19,color:.systemMint)
            return
        }
        if model.guide {
            let path = NSBezierPath(); path.lineWidth = 1; path.setLineDash([3,7],count:2,phase:0)
            for beat in 0..<4 { for n in 0...80 { let point = xy(ConductorGeometry.point(beat:beat,phase:Double(n)/80)); if n == 0 { path.move(to:point) } else { path.line(to:point) } } }
            NSColor(calibratedRed:0.16,green:0.23,blue:0.30,alpha:1).setStroke(); path.stroke()
        }
        if let timing = snapshot.timing, snapshot.state != .ready, snapshot.state != .error, p?.ended == false, !model.utilityOpen {
            for n in 0..<45 {
                let q = timing.position(max(snapshot.segmentStart,snapshot.time-Double(45-n)*0.0045))
                dot(xy(ConductorGeometry.point(beat:q.beat,phase:q.f)),radius:2+Double(n)/45*2,color:NSColor(calibratedRed:182/255,green:230/255,blue:222/255,alpha:Double(n)/45*0.45))
            }
        }
        dot(xy(ConductorGeometry.point(beat:p?.beat ?? 0,phase:p?.f ?? 0)),radius:7,color:p?.ended == true ? .gray : NSColor(calibratedRed:228/255,green:1,blue:247/255,alpha:1))
    }
}

@MainActor final class PerformanceKeys {
    private var monitor: Any?
    init(model:PerformanceModel) {
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak model] event in
            guard let model, !model.shortcutsBlocked, !event.isARepeat, event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable { return event }
            if NSApp.keyWindow?.firstResponder is NSPopUpButton { return event }
            switch event.keyCode {
            case 124: model.cue(); return nil
            case 49: if NSApp.keyWindow?.firstResponder is NSButton { return event }; model.toggle(); return nil
            case 4: model.clean.toggle(); return nil
            default: return event
            }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
