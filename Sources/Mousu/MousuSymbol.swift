import SwiftUI

/// Shared foreground for the app, menu panel, menu bar, and Composer artwork.
struct MousuSymbol: View {
    let size: CGFloat
    var paused = false

    private var original: some View {
        Image(systemName: "cursorarrow.rays")
            .font(.system(size: size * 0.51, weight: .medium))
            .frame(width: size, height: size)
    }

    var body: some View {
        ZStack {
            original
                .mask {
                    Path { path in
                        path.addRect(CGRect(x: 0, y: 0, width: size, height: size))
                        if paused {
                            // Only the upper-left diagonal pip moves. Preserve
                            // the original cursor and all five remaining rays.
                            path.addRect(
                                CGRect(x: size * 0.27, y: size * 0.27, width: size * 0.16, height: size * 0.17))
                        }
                    }
                    .fill(style: FillStyle(eoFill: true))
                }
            if paused {
                // Match the original vertical pip exactly, with no resizing.
                // This is the relocated diagonal pip in its upright orientation.
                original
                    .mask {
                        Path { path in
                            path.addRect(
                                CGRect(x: size * 0.45, y: size * 0.20, width: size * 0.11, height: size * 0.20))
                        }
                        .fill()
                    }
                    .offset(x: -size * 0.09)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
