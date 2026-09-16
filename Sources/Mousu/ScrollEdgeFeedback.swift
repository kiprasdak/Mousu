import Foundation

/// Short, bounded ripples used only by the local Try it canvas.
struct ScrollEdgeFeedback {
    private enum Edge { case left, right, top, bottom }
    private struct Ripple {
        let edge: Edge
        let time: TimeInterval
        var strength: Double
    }
    private var ripples: [Ripple] = []
    private struct SparseAccent {
        let time: TimeInterval
        let initial: Double
        let peak: Double
    }
    private var sparseAccent: SparseAccent?

    private static let minimumEdgeSpeed = 0.55
    private static let lifetime = 0.7 / (minimumEdgeSpeed * dotSpeeds.min()!)

    mutating func record(x: Double, y: Double, at time: TimeInterval) {
        guard x.isFinite, y.isFinite, x != 0 || y != 0 else { return }
        _ = expire(at: time)
        let currentAccent = sparseIntensity(at: time)
        sparseAccent = SparseAccent(
            time: time, initial: currentAccent,
            peak: max(currentAccent, min(1, 0.45 + hypot(x, y) / 96)))
        let largest = max(abs(x), abs(y))
        let strength = min(1, max(0.18, hypot(x, y) / 48))
        if x != 0 { add(x > 0 ? .right : .left, strength: strength * abs(x) / largest, at: time) }
        if y != 0 { add(y > 0 ? .bottom : .top, strength: strength * abs(y) / largest, at: time) }
        if ripples.count > 24 { ripples.removeFirst(ripples.count - 24) }
    }

    private mutating func add(_ edge: Edge, strength: Double, at time: TimeInterval) {
        // Coalesce high-frequency trackpad samples, preserving the wave's starting time.
        if let index = ripples.lastIndex(where: { $0.edge == edge }), time - ripples[index].time < 0.075 {
            ripples[index].strength = min(1, ripples[index].strength + strength * 0.25)
        } else {
            ripples.append(Ripple(edge: edge, time: time, strength: strength))
        }
    }

    @discardableResult
    mutating func expire(at time: TimeInterval) -> Bool {
        ripples.removeAll { time - $0.time >= Self.lifetime }
        if let accent = sparseAccent, time - accent.time >= 2.3 { sparseAccent = nil }
        return !ripples.isEmpty || sparseAccent != nil
    }

    /// Retarget from the current value so repeated scroll events never flash or snap.
    func sparseIntensity(at time: TimeInterval) -> Double {
        guard let accent = sparseAccent else { return 0 }
        let age = max(0, time - accent.time)
        if age < 0.1 {
            let t = age / 0.1
            return accent.initial + (accent.peak - accent.initial) * t * t * (3 - 2 * t)
        }
        let t = min(1, (age - 0.1) / 2.2)
        return accent.peak * (1 - t * t * (3 - 2 * t))
    }

    /// Resolve time once per frame; every dot samples the same smooth field.
    func field(at time: TimeInterval, speed: Double = 1) -> Field {
        var weights = SIMD4<Double>(repeating: 0)
        for ripple in ripples {
            let progress = (time - ripple.time) * speed / 0.7
            guard progress > 0, progress < 1 else { continue }
            // Fast, smooth rise with a longer release. No spatial delay or dead bands.
            let attack = min(1, progress / 0.2)
            let release = (progress - 0.2) / 0.8
            let envelope =
                progress < 0.2
                ? attack * attack * (3 - 2 * attack)
                : 1 - release * release * (3 - 2 * release)
            let index: Int
            switch ripple.edge {
            case .left: index = 0
            case .right: index = 1
            case .top: index = 2
            case .bottom: index = 3
            }
            weights[index] += ripple.strength * envelope
        }
        let energy = weights[0] + weights[1] + weights[2] + weights[3]
        if energy > 0 {
            // Compress event volume before applying the spatial gradient, so rapid
            // scrolling never clips multiple rows to one maximum dot size.
            weights *= (1 - exp(-energy * 1.6)) / energy
        }
        return Field(weights: weights)
    }

    /// Cache a few temporal samples per frame and interpolate across the canvas.
    /// Dots near each active edge take about 1.8 times as long to swell and settle.
    func spatialField(at time: TimeInterval, speed: Double = 1) -> SpatialField {
        SpatialField(
            samples: (0...8).map { index in
                field(
                    at: time, speed: speed * (Self.minimumEdgeSpeed + (1 - Self.minimumEdgeSpeed) * Double(index) / 8))
            })
    }

    struct SpatialField {
        fileprivate let samples: [Field]

        func intensity(at point: CGPoint, in size: CGSize, spatialExponent: Double = 2.2) -> Double {
            guard size.width > 0, size.height > 0 else { return 0 }
            // Each direction keeps its own timing: horizontal scroll does not
            // slow dots at the top or bottom, and diagonal input follows both axes.
            let distances = [point.x, size.width - point.x, point.y, size.height - point.y]
            var weights = SIMD4<Double>(repeating: 0)
            for edge in 0..<4 {
                let extent = edge < 2 ? size.width : size.height
                let progress = min(1, max(0, distances[edge]) / (extent / 2))
                let position = progress * progress * (3 - 2 * progress) * Double(samples.count - 1)
                let lower = Int(position)
                let upper = min(lower + 1, samples.count - 1)
                let fraction = position - Double(lower)
                weights[edge] =
                    samples[lower].weights[edge] * (1 - fraction)
                    + samples[upper].weights[edge] * fraction
            }
            return Field(weights: weights).intensity(at: point, in: size, spatialExponent: spatialExponent)
        }
    }

    /// Resolve event envelopes once per frame; the GPU evaluates each dot's spatial response.
    func renderWeights(at time: TimeInterval) -> [SIMD4<Float>] {
        Self.dotSpeeds.flatMap { speed in
            spatialField(at: time, speed: speed).samples.map { sample in
                SIMD4<Float>(
                    Float(sample.weights.x), Float(sample.weights.y), Float(sample.weights.z), Float(sample.weights.w))
            }
        }
    }

    struct DotVariation {
        let brightness: Double
        let scale: Double
        let speedIndex: Int
        let sparseAccent: Double
    }

    static let dotSpeeds = [0.94, 0.97, 1.0, 1.03, 1.06]

    static func variation(column: Int, row: Int) -> DotVariation {
        // Stable grid identity, not frame randomness: dots never flicker or change personality.
        var seed = UInt64(bitPattern: Int64(column)) &* 0x9E37_79B9_7F4A_7C15
        seed ^= UInt64(bitPattern: Int64(row)) &* 0xBF58_476D_1CE4_E5B9
        seed = (seed ^ (seed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        seed = (seed ^ (seed >> 27)) &* 0x94D0_49BB_1331_11EB
        seed ^= seed >> 31
        return DotVariation(
            brightness: 0.92 + Double(seed & 255) / 255 * 0.16,
            scale: 0.94 + Double((seed >> 8) & 255) / 255 * 0.12,
            speedIndex: Int((seed >> 16) % 5),
            sparseAccent: (seed >> 24) % 48 == 0 ? 0.7 + Double((seed >> 32) & 255) / 255 * 0.3 : 0)
    }

    struct Field {
        fileprivate let weights: SIMD4<Double>

        func intensity(at point: CGPoint, in size: CGSize, spatialExponent: Double = 2.2) -> Double {
            guard size.width > 0, size.height > 0 else { return 0 }
            let x = min(1, max(0, point.x / size.width))
            let y = min(1, max(0, point.y / size.height))
            func ramp(_ position: Double, across: Double) -> Double {
                // A trace of scaling reaches the far side. The subtle transverse
                // slope also distinguishes neighboring lines perpendicular to travel.
                (0.001 + 0.999 * pow(position, spatialExponent)) * (0.995 + 0.005 * across)
            }
            return weights[0] * ramp(1 - x, across: y)
                + weights[1] * ramp(x, across: y)
                + weights[2] * ramp(1 - y, across: x)
                + weights[3] * ramp(y, across: x)
        }
    }
}
