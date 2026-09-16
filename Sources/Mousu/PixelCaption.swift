import AppKit

/// Proportional, mixed-case bitmap lettering inspired by early desktop interfaces.
/// Integer pixels keep the terminal lettering blocky regardless of installed fonts.
enum PixelCaption {
    static func width(of text: String, scale: CGFloat) -> CGFloat {
        let advances = text.map { character -> Int in
            guard let rows = glyphs[character] else { return 4 }
            let occupied = rows.reduce(UInt8(0), |)
            let columns = (0..<5).filter { occupied & (1 << (4 - $0)) != 0 }
            return (columns.last ?? 4) - (columns.first ?? 0) + 2
        }
        return CGFloat(max(0, advances.reduce(0, +) - 1)) * scale
    }

    static func draw(_ text: String, at origin: CGPoint, scale: CGFloat, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        context.setFillColor(color.cgColor)
        var cursor = origin.x
        for character in text {
            guard let rows = glyphs[character] else {
                cursor += 4 * scale
                continue
            }
            let occupied = rows.reduce(UInt8(0), |)
            let columns = (0..<5).filter { occupied & (1 << (4 - $0)) != 0 }
            let left = columns.first ?? 0
            let right = columns.last ?? 4
            for (row, bits) in rows.enumerated() {
                for bit in 0..<5 where bits & (1 << (4 - bit)) != 0 {
                    context.fill(
                        CGRect(
                            x: cursor + CGFloat(bit - left) * scale,
                            y: origin.y + CGFloat(row) * scale, width: scale, height: scale))
                }
            }
            cursor += CGFloat(right - left + 2) * scale
        }
    }

    private static let glyphs: [Character: [UInt8]] = [
        "A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30],
        "C": [14, 17, 16, 16, 16, 17, 14], "D": [30, 17, 17, 17, 17, 17, 30],
        "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
        "G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17],
        "I": [14, 4, 4, 4, 4, 4, 14], "J": [7, 2, 2, 2, 18, 18, 12],
        "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
        "M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 25, 21, 19, 17, 17, 17],
        "O": [14, 17, 17, 17, 17, 17, 14], "P": [30, 17, 17, 30, 16, 16, 16],
        "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17],
        "S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4],
        "U": [17, 17, 17, 17, 17, 17, 14], "V": [17, 17, 17, 17, 17, 10, 4],
        "W": [17, 17, 17, 21, 21, 21, 10], "X": [17, 17, 10, 4, 10, 17, 17],
        "Y": [17, 17, 10, 4, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31],
        "a": [0, 0, 14, 1, 15, 17, 15], "b": [16, 16, 30, 17, 17, 17, 30],
        "c": [0, 0, 14, 17, 16, 17, 14], "d": [1, 1, 15, 17, 17, 17, 15],
        "e": [0, 0, 14, 17, 31, 16, 14], "f": [6, 9, 8, 28, 8, 8, 8],
        "g": [0, 0, 15, 17, 17, 17, 15, 1, 14], "h": [16, 16, 30, 17, 17, 17, 17],
        "i": [4, 0, 4, 4, 4, 4, 4], "j": [2, 0, 2, 2, 2, 2, 2, 18, 12],
        "k": [16, 16, 18, 20, 24, 20, 18], "l": [4, 4, 4, 4, 4, 4, 4],
        "m": [0, 0, 26, 21, 21, 21, 21], "n": [0, 0, 30, 17, 17, 17, 17],
        "o": [0, 0, 14, 17, 17, 17, 14], "p": [0, 0, 30, 17, 17, 17, 30, 16, 16],
        "q": [0, 0, 15, 17, 17, 17, 15, 1, 1], "r": [0, 0, 22, 25, 16, 16, 16],
        "s": [0, 0, 15, 16, 14, 1, 30], "t": [8, 8, 28, 8, 8, 9, 6],
        "u": [0, 0, 17, 17, 17, 17, 15], "v": [0, 0, 17, 17, 17, 10, 4],
        "w": [0, 0, 17, 17, 21, 21, 10], "x": [0, 0, 17, 10, 4, 10, 17],
        "y": [0, 0, 17, 17, 17, 17, 15, 1, 14], "z": [0, 0, 31, 2, 4, 8, 31],
        "0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14],
        "2": [14, 17, 1, 2, 4, 8, 31], "3": [30, 1, 1, 14, 1, 1, 30],
        "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 16, 30, 1, 1, 30],
        "6": [14, 16, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8],
        "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 1, 14],
        ",": [0, 0, 0, 0, 0, 6, 6, 4, 8],
        ".": [0, 0, 0, 0, 0, 6, 6], "-": [0, 0, 0, 31, 0, 0, 0],
        "−": [0, 0, 0, 31, 0, 0, 0], "+": [0, 4, 4, 31, 4, 4, 0],
        "↑": [4, 14, 21, 4, 4, 4, 4], "↓": [4, 4, 4, 4, 21, 14, 4],
        "←": [0, 4, 8, 31, 8, 4, 0], "→": [0, 4, 2, 31, 2, 4, 0],
    ]
}
