import CoreGraphics
import Foundation

/// Click waves stay in viewport coordinates while the dot grid scrolls through them.
struct DotClickRipple {
    private struct Source {
        let point: CGPoint
        // Nil identifies the outgoing wave. Reflected rays track their own wall contact.
        let verticalWall: Bool?
        let distanceToWall: Double
    }
    private struct Ripple {
        let center: CGPoint
        let sources: [Source]
        let time: TimeInterval
        var supersededAt: TimeInterval?
    }
    private var ripples: [Ripple] = []
    static let speed = 240.0
    static let reflectedSpeed = 120.0
    static let bounceFadeDuration = 0.35
    static let duration = DotGlowStyle.lifetime * 3

    mutating func record(_ point: CGPoint, at time: TimeInterval, bounds: CGRect? = nil) {
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { return }
        _ = expire(at: time)
        // Keep rapid clicks from forming a stack of rings. Old waves ease out
        // from their current brightness; very close clicks share the latest wave.
        if let latest = ripples.last, time - latest.time < 0.12 { return }
        for index in ripples.indices where ripples[index].supersededAt == nil {
            ripples[index].supersededAt = time
        }
        var sources = [Source(point: point, verticalWall: nil, distanceToWall: 0)]
        if let bounds, bounds.width > 0, bounds.height > 0 {
            sources += [
                Source(
                    point: CGPoint(x: 2 * bounds.minX - point.x, y: point.y),
                    verticalWall: true, distanceToWall: max(0, point.x - bounds.minX)),
                Source(
                    point: CGPoint(x: 2 * bounds.maxX - point.x, y: point.y),
                    verticalWall: true, distanceToWall: max(0, bounds.maxX - point.x)),
                Source(
                    point: CGPoint(x: point.x, y: 2 * bounds.minY - point.y),
                    verticalWall: false, distanceToWall: max(0, point.y - bounds.minY)),
                Source(
                    point: CGPoint(x: point.x, y: 2 * bounds.maxY - point.y),
                    verticalWall: false, distanceToWall: max(0, bounds.maxY - point.y)),
            ]
        }
        ripples.append(Ripple(center: point, sources: sources, time: time, supersededAt: nil))
        if ripples.count > 8 { ripples.removeFirst(ripples.count - 8) }
    }

    @discardableResult
    mutating func expire(at time: TimeInterval) -> Bool {
        ripples.removeAll {
            time - $0.time >= Self.duration || $0.supersededAt.map { time - $0 >= 0.2 } == true
        }
        return !ripples.isEmpty
    }

    struct RenderSource {
        var geometry: SIMD4<Float>
        var timing: SIMD4<Float>
    }

    func renderSources(at time: TimeInterval, reduceMotion: Bool) -> [RenderSource] {
        ripples.flatMap { ripple -> [RenderSource] in
            let age = time - ripple.time
            guard age >= 0, age < Self.duration else { return [] }
            var fade = DotGlowStyle.fade(age: reduceMotion ? age : age / 3)
            if let superseded = ripple.supersededAt {
                let t = min(1, max(0, (time - superseded) / 0.2))
                fade *= 1 - t * t * (3 - 2 * t)
            }
            return ripple.sources.compactMap { source in
                if reduceMotion && source.verticalWall != nil { return nil }
                return RenderSource(
                    geometry: SIMD4(
                        Float(source.point.x), Float(source.point.y),
                        source.verticalWall.map { $0 ? 1 : 0 } ?? -1, Float(source.distanceToWall)),
                    timing: SIMD4(Float(age), Float(fade), 0, 0))
            }
        }
    }

    func intensity(at point: CGPoint, time: TimeInterval, reduceMotion: Bool = false) -> Double {
        var glow = 0.0
        for ripple in ripples {
            let age = time - ripple.time
            guard age >= 0, age < Self.duration else { continue }
            let radius = reduceMotion ? 0 : Self.speed * age
            var fade = DotGlowStyle.fade(age: reduceMotion ? age : age / 3)
            if let superseded = ripple.supersededAt {
                let t = min(1, max(0, (time - superseded) / 0.2))
                fade *= 1 - t * t * (3 - 2 * t)
            }
            for source in ripple.sources {
                if reduceMotion && source.verticalWall != nil { continue }
                let distance = hypot(point.x - source.point.x, point.y - source.point.y)
                var waveRadius = radius
                var reflectedFade = 1.0
                if let vertical = source.verticalWall {
                    let axisDistance = vertical ? abs(point.x - source.point.x) : abs(point.y - source.point.y)
                    // Locate this ray's wall intersection, not the whole circle's first contact.
                    let fraction = axisDistance > 0 ? min(1, source.distanceToWall / axisDistance) : 0
                    let beforeBounce = distance * fraction
                    let bounceTime = beforeBounce / Self.speed
                    let sinceBounce = age - bounceTime
                    guard sinceBounce >= 0 else { continue }
                    waveRadius = beforeBounce + Self.reflectedSpeed * sinceBounce
                    let t = min(1, sinceBounce / Self.bounceFadeDuration)
                    reflectedFade = 1 - t * t * (3 - 2 * t)
                }
                let strength = DotGlowStyle.strength(distance: abs(distance - waveRadius))
                glow = max(glow, strength * fade * reflectedFade)
            }
        }
        return glow
    }
}
