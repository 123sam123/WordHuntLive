import Foundation

/// Rough estimate of how hard a path is to drag accurately on a phone.
///
///   1.0  per segment (tile-to-tile move)
/// + 0.25 per diagonal segment (diagonals are easier to clip a wrong tile on)
/// + 0.5  per change of direction
/// + 0.5  extra when the turn is sharper than 90° (doubling back)
///
/// A straight 5-letter word scores 4.0; a zig-zag of the same length is much higher.
public enum GestureComplexity {
    public static func score(_ path: [GridCoord]) -> Double {
        guard path.count > 1 else { return 0 }
        var total = 0.0
        var prev: (Int, Int)?
        for i in 1..<path.count {
            let d = (path[i].row - path[i - 1].row, path[i].column - path[i - 1].column)
            total += 1
            if d.0 != 0 && d.1 != 0 { total += 0.25 }
            if let p = prev, p != d {
                total += 0.5
                if p.0 * d.0 + p.1 * d.1 < 0 { total += 0.5 } // dot < 0 → angle > 90°
            }
            prev = d
        }
        return total
    }
}
