import CoreGraphics
import Foundation

/// Shared appearance for pointer trails and click waves.
enum DotGlowStyle {
    static let lifetime = 0.8

    static func strength(distance: Double) -> Double {
        pow(max(0, 1 - distance / 25), 1.4)
    }

    static func fade(age: TimeInterval) -> Double {
        let remaining = max(0, min(1, 1 - age / lifetime))
        return remaining * remaining * (3 - 2 * remaining)
    }
}

/// A bounded, short-lived glow stored on grid dots rather than a drawn pointer line.
struct DotPathHighlight {
    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }
    private struct Glow {
        let time: TimeInterval
        let strength: Double
    }
    private var cells: [Cell: Glow] = [:]
    private var previous: CGPoint?

    mutating func record(_ point: CGPoint, at time: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite else { return }
        _ = expire(at: time)
        let start = previous ?? point
        let steps = min(512, max(1, Int(ceil(hypot(point.x - start.x, point.y - start.y) / 6))))
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let p = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
            let column = Int(floor((p.x - 1) / 16))
            let row = Int(floor((p.y - 1) / 16))
            for x in (column - 1)...(column + 2) {
                for y in (row - 1)...(row + 2) {
                    let distance = hypot(CGFloat(x * 16 + 1) - p.x, CGFloat(y * 16 + 1) - p.y)
                    let strength = DotGlowStyle.strength(distance: distance)
                    guard strength > 0 else { continue }
                    let key = Cell(x: x, y: y)
                    let remaining = cells[key].map { faded($0, at: time) } ?? 0
                    cells[key] = Glow(time: time, strength: max(remaining, strength))
                }
            }
        }
        previous = point
        if cells.count > 4096 { cells = cells.filter { time - $0.value.time < 0.15 } }
    }

    mutating func endStroke() { previous = nil }

    @discardableResult
    mutating func expire(at time: TimeInterval) -> Bool {
        cells = cells.filter { time - $0.value.time < DotGlowStyle.lifetime }
        if cells.isEmpty { previous = nil }
        return !cells.isEmpty
    }

    func intensity(at point: CGPoint, time: TimeInterval) -> Double {
        let key = Cell(x: Int(((point.x - 1) / 16).rounded()), y: Int(((point.y - 1) / 16).rounded()))
        return cells[key].map { faded($0, at: time) } ?? 0
    }

    /// Write only active dots into a reusable GPU instance buffer.
    func writeIntensities(
        into values: UnsafeMutableBufferPointer<Float>, firstColumn: Int, firstRow: Int,
        columns: Int, rows: Int, stride: Int, at time: TimeInterval
    ) {
        values.initialize(repeating: 0)
        for (cell, glow) in cells {
            let x = cell.x - firstColumn
            let y = cell.y - firstRow
            guard x >= 0, y >= 0, x % stride == 0, y % stride == 0,
                x / stride < columns, y / stride < rows
            else { continue }
            values[(y / stride) * columns + x / stride] = Float(faded(glow, at: time))
        }
    }

    private func faded(_ glow: Glow, at time: TimeInterval) -> Double {
        glow.strength * DotGlowStyle.fade(age: time - glow.time)
    }
}
