import Foundation

public enum ConductorGeometry {
    private static let landings: [CGPoint] = [CGPoint(x: 0, y: 0.60), CGPoint(x: 0.66, y: 0.58), CGPoint(x: -0.66, y: 0.58), CGPoint(x: -0.06, y: 0.56)]
    private static let controls: [[CGPoint]] = [
        [CGPoint(x: 0.08, y: 0.43), CGPoint(x: 0.66, y: 0.43)],
        [CGPoint(x: 0.43, y: 0.34), CGPoint(x: -0.43, y: 0.34)],
        [CGPoint(x: -0.66, y: 0.35), CGPoint(x: -0.10, y: 0.39)],
        [CGPoint(x: 0.18, y: -0.2733333333), CGPoint(x: 0, y: -0.2733333333)]
    ]
    public static func point(beat: Int, phase: Double) -> CGPoint {
        let beat = ((beat % 4) + 4) % 4
        let a = landings[beat], b = controls[beat][0], c = controls[beat][1], d = landings[(beat + 1) % 4]
        let t = phase, u = 1 - t
        return CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                       y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
    }
}
