import Foundation

/// A guide line shown while an object snaps (canvas points; `position` is x for vertical guides, y for horizontal).
struct SnapGuide {
    let vertical: Bool
    let position: CGFloat
    let from: CGFloat
    let to: CGFloat
}

/// Straight edges found in the screenshot (window borders, cards, toolbars…), used as snap targets.
/// An edge is a run of at least `minRun` pixels where the color changes between neighbouring columns (or rows).
final class EdgeMap {
    /// Pixel x where the color changes between columns x-1 and x → row ranges (pixels) of that edge.
    private(set) var vertical: [Int: [Range<Int>]] = [:]
    /// Pixel y where the color changes between rows y-1 and y → column ranges (pixels).
    private(set) var horizontal: [Int: [Range<Int>]] = [:]

    init(sampler: PixelSampler, tolerance: Int = 10, minRun: Int) {
        let w = sampler.width, h = sampler.height
        guard w > 1, h > 1 else { return }
        for x in 1..<w {
            var start = -1
            for y in 0..<h {
                if sampler.differs(x - 1, y, x, y, tolerance: tolerance) {
                    if start < 0 { start = y }
                } else if start >= 0 {
                    if y - start >= minRun { vertical[x, default: []].append(start..<y) }
                    start = -1
                }
            }
            if start >= 0, h - start >= minRun { vertical[x, default: []].append(start..<h) }
        }
        for y in 1..<h {
            var start = -1
            for x in 0..<w {
                if sampler.differs(x, y - 1, x, y, tolerance: tolerance) {
                    if start < 0 { start = x }
                } else if start >= 0 {
                    if x - start >= minRun { horizontal[y, default: []].append(start..<x) }
                    start = -1
                }
            }
            if start >= 0, w - start >= minRun { horizontal[y, default: []].append(start..<w) }
        }
    }
}
