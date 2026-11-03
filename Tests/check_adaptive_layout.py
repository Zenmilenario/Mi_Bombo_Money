"""Comprueba la geometría real de las filas sin el SDK de SwiftUI.

Los subviews simulados incluyen texto que cambia de altura al estrecharse.
Esta prueba no sustituye la compilación iOS ni la revisión en dispositivos.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MiPatrimonio/Shared/ReusableViews.swift").read_text(encoding="utf-8")
start = source.index("private struct AdaptiveValueLayout: Layout {")
end = source.index("\nstruct AdaptiveSummaryPair:", start)
layout = source[start:end]

fixtures = r"""
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
protocol Layout {}
struct ProposedViewSize {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    static let unspecified = ProposedViewSize()
}
struct UnitPoint { static let topLeading = UnitPoint() }
final class TestSubview {
    let idealWidth: CGFloat
    let lineHeight: CGFloat
    var frame = CGRect.zero
    init(_ width: CGFloat, _ height: CGFloat) { idealWidth = width; lineHeight = height }
    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        precondition(proposal.height == nil, "A row must measure its content without accepting the List height")
        if idealWidth == 0 { return .zero }
        let width = min(idealWidth, max(1, proposal.width ?? idealWidth))
        return CGSize(width: width, height: ceil(idealWidth / width) * lineHeight)
    }
    func place(at point: CGPoint, anchor: UnitPoint, proposal: ProposedViewSize) {
        frame = CGRect(origin: point, size: sizeThatFits(proposal))
    }
}
typealias Subviews = [TestSubview]
"""
checks = r"""
@main struct RowLayoutCheck {
    static func main() {
        var cases = 0
        for width: CGFloat in [160, 320, 390, 600, 834, 1194] {
            for accessible in [false, true] {
                for labelWidth: CGFloat in [120, 270, 620, 1400] {
                    for valueWidth: CGFloat in [0, 90, 240] {
                        let views = [TestSubview(labelWidth, 22), TestSubview(valueWidth, 20)]
                        let layout = AdaptiveValueLayout(forceVertical: accessible)
                        var cache: () = ()
                        let natural = layout.sizeThatFits(proposal: ProposedViewSize(width: width), subviews: views, cache: &cache)
                        precondition(natural.width == width && natural.height.isFinite && natural.height > 0)
                        for proposedHeight: CGFloat in [0, 44, 1000, 100_000] {
                            let proposal = ProposedViewSize(width: width, height: proposedHeight)
                            let size = layout.sizeThatFits(proposal: proposal, subviews: views, cache: &cache)
                            precondition(size == natural, "List height must not inflate a row")
                            let bounds = CGRect(x: 19, y: 23, width: width, height: size.height)
                            layout.placeSubviews(in: bounds, proposal: proposal, subviews: views, cache: &cache)
                            for view in views where view.frame.width > 0 {
                                precondition(view.frame.minX >= bounds.minX && view.frame.maxX <= bounds.maxX + 0.01)
                                precondition(view.frame.minY >= bounds.minY && view.frame.maxY <= bounds.maxY + 0.01)
                            }
                            if !views[0].frame.isEmpty && !views[1].frame.isEmpty {
                                precondition(!views[0].frame.intersects(views[1].frame),
                                    "Label and amount overlap: width=\(width), accessible=\(accessible), label=\(labelWidth), value=\(valueWidth), frames=\(views.map { $0.frame })")
                            }
                            cases += 1
                        }
                        if valueWidth == 0 {
                            precondition(natural.height == views[0].frame.height, "No trailing action means no empty gap")
                        }
                    }
                }
            }
        }
        let normal = AdaptiveValueLayout(forceVertical: false)
        var cache: () = ()
        let account = normal.sizeThatFits(proposal: ProposedViewSize(width: 1194, height: 10000),
            subviews: [TestSubview(270, 66), TestSubview(90, 42)], cache: &cache)
        precondition(account.height == 66, "A short account row must remain compact on iPad")
        print("Adaptive rows passed: \(cases) proposals, wrapping text, large text, empty actions and no inflated iPad rows.")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="mibombo-row-layout-") as directory:
    swift_file = Path(directory) / "RowLayoutCheck.swift"
    executable = Path(directory) / "row-layout-check"
    swift_file.write_text(fixtures + layout + checks, encoding="utf-8")
    subprocess.run([os.environ.get("SWIFTC", "swiftc"), "-swift-version", "5", "-parse-as-library",
                    str(swift_file), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
