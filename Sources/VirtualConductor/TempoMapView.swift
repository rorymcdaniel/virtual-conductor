import SwiftUI
import Charts

struct TempoMapView: View {
    let entries: [PracticeTempo.Entry]
    let end: Double
    let selected: Double?
    let select: (PracticeTempo.Entry) -> Void

    private var active: PracticeTempo.Entry? {
        selected.flatMap { q in entries.last { $0.quarter <= q } }
    }

    private var measureTicks: [Double] {
        let measures = Int(ceil(end / 4))
        let target = max(1, Double(measures) / 6)
        let scale = pow(10, floor(log10(target)))
        let step = Int(([1.0, 2, 5, 10].first { $0 * scale >= target } ?? 10) * scale)
        return [1] + stride(from: max(2, step), through: measures, by: step).map(Double.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tempo map").font(.headline)
                Spacer()
                if entries.contains(where: { $0.source == .practice }) {
                    Label("Practice marking", systemImage: "diamond.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            Chart {
                ForEach(entries) { entry in
                    LineMark(x: .value("Measure", 1 + entry.quarter / 4), y: .value("BPM", entry.bpm))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.mint)
                    if entry.source == .practice {
                        PointMark(x: .value("Measure", 1 + entry.quarter / 4), y: .value("BPM", entry.bpm))
                            .symbol(.diamond).foregroundStyle(Color.orange)
                    }
                }
                if let last = entries.last {
                    LineMark(x: .value("Measure", 1 + end / 4), y: .value("BPM", last.bpm))
                        .interpolationMethod(.stepEnd).foregroundStyle(Color.mint)
                }
                if let selected {
                    RuleMark(x: .value("Selected measure", 1 + selected / 4))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartXScale(domain: 1...(1 + end / 4))
            .chartXAxis { AxisMarks(values: measureTicks) { value in
                AxisGridLine(); AxisTick()
                if let m = value.as(Double.self) { AxisValueLabel { Text(String(Int(m))) } }
            } }
            .chartXAxisLabel("Measure · 1–\(Int(ceil(end / 4)))")
            .chartYAxisLabel("Planned BPM")
            .chartYScale(domain: .automatic(includesZero: false))
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onTapGesture { point in
                        guard let frame = proxy.plotFrame else { return }
                        let plot = geometry[frame]
                        guard plot.contains(point), let m: Double = proxy.value(atX: point.x - plot.minX),
                              let entry = entries.last(where: { $0.quarter <= (m - 1) * 4 }) else { return }
                        select(entry)
                    }
                }
            }
            .frame(height: 150)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            Button { select(entry) } label: {
                                HStack {
                                    Text(PracticeTempoView.location(entry.quarter)).monospacedDigit()
                                    Spacer()
                                    Text(entry.source.rawValue).foregroundStyle(.secondary)
                                    Text("\(entry.bpm.formatted(.number.precision(.fractionLength(0...3)))) BPM")
                                        .monospacedDigit().frame(minWidth: 100, alignment: .trailing)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(active?.id == entry.id ? Color.mint.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(entry.id)
                        }
                    }
                }
                .onAppear { if let id = active?.id { reader.scrollTo(id, anchor: .center) } }
                .onChange(of: active?.id) { _, id in if let id { reader.scrollTo(id, anchor: .center) } }
            }
            .frame(height: 120)
        }
    }
}
