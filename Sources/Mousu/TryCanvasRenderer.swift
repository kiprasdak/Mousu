import AppKit
import Metal
import QuartzCore

/// Resolution is independent of desktop size. The system drawable pool and our
/// scene texture use bounded pixel sizes; input coordinates remain in view points.
struct CanvasRenderSize: Equatable {
    let width: Int
    let height: Int
    static let pixelBudget = 2_500_000

    init?(size: CGSize, scale: CGFloat, budget: Int = Self.pixelBudget) {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
            size.width > 0, size.height > 0, size.width <= 1_000_000, size.height <= 1_000_000, scale > 0, budget > 0
        else { return nil }
        let area = size.width * size.height
        guard area.isFinite else { return nil }
        let factor = min(scale, sqrt(CGFloat(budget) / area), 4096 / max(size.width, size.height))
        // Preserve native pixel alignment whenever the surface fits the budget.
        width = max(1, Int(floor(size.width * factor)))
        height = max(1, Int(floor(size.height * factor)))
    }
    var size: CGSize { CGSize(width: width, height: height) }
}

struct CanvasFrame {
    var size: CGSize
    var scale: CGFloat = 2
    var offset = CGSize.zero
    var color = SIMD4<Float>(0.22, 0.46, 0.98, 1)
    var dark = true
    var reduceMotion = false
    var includesCaptions = true
    var noticeActive = false
    var effect = TryAreaEffect.fast
    var time: TimeInterval
    var power = CRTSignal.Power(width: 1, height: 1, brightness: 1)
    var signalTime = 0.0
    var reveal = 1.0
    var coordinates = ""
    var coordinateOpacity = 0.0
    var noticeOpacity = 0.0
    var edges = ScrollEdgeFeedback()
    var path = DotPathHighlight()
    var clicks = DotClickRipple()
}

/// Completion handlers never touch AppKit or wait for the main actor.
final class CanvasGPUFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = [false, false]
    private var duration: Double?
    private var failures = 0
    func acquire() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = busy.firstIndex(of: false) else { return nil }
        busy[index] = true
        return index
    }
    func finish(_ index: Int, seconds: Double = 0, failed: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        busy[index] = false
        if seconds > 0 {
            duration = seconds
        }
        if failed { failures += 1 }
    }
    var lastDuration: Double? { lock.withLock { duration } }
    var failureCount: Int { lock.withLock { failures } }
}

@MainActor
private final class CanvasMetalPipelines {
    enum Failure: Error { case metalUnavailable, pipelineMissing, allocationFailed }
    static let shared: Result<CanvasMetalPipelines, Error> = Result { try CanvasMetalPipelines() }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let dots: MTLRenderPipelineState
    let caption: MTLRenderPipelineState
    let screen: MTLRenderPipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.metalUnavailable
        }
        self.device = device
        self.queue = queue
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let library: MTLLibrary
        if let url = Bundle.main.url(forResource: "TryCanvas", withExtension: "metallib") {
            library = try device.makeLibrary(URL: url)
        } else {
            // SwiftPM development builds; shipped bundles contain precompiled shaders.
            library = try device.makeLibrary(source: TryCanvasShaders.source, options: options)
        }
        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw Failure.pipelineMissing
            }
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = blended
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        dots = try pipeline("dots", "dotPixel", blended: true)
        caption = try pipeline("caption", "captionPixel", blended: true)
        screen = try pipeline("fullscreen", "screen", blended: false)
    }
}

@MainActor
private final class CanvasCaptionTexture {
    private var key = ""
    private var context: CGContext?
    private(set) var texture: MTLTexture?
    private(set) var logicalSize = CGSize.zero
    func update(device: MTLDevice, key: String, size: CGSize, scale: CGFloat, draw: () -> Void) {
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard self.key != key || texture?.width != width || texture?.height != height else { return }
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let texture, let context, let data = context.data else { return }
        context.saveGState()
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: width * 4)
        self.key = key
        logicalSize = size
    }
}

@MainActor
final class TryCanvasRenderer {
    private struct Uniforms {
        var viewport, scroll, accent, appearance, power, grid, dynamics: SIMD4<Float>
    }
    private let pipelines: CanvasMetalPipelines
    let flight = CanvasGPUFlight()
    private var scene: MTLTexture?
    private var paths: [MTLBuffer?] = [nil, nil]
    // Per-flight caption textures prevent CPU uploads from overwriting a GPU reader.
    private var headers = [CanvasCaptionTexture(), CanvasCaptionTexture()]
    private var coordinates = [CanvasCaptionTexture(), CanvasCaptionTexture()]
    private var notices = [CanvasCaptionTexture(), CanvasCaptionTexture()]
    private(set) var lastError: String?

    init() throws { pipelines = try CanvasMetalPipelines.shared.get() }

    func configure(_ layer: CAMetalLayer, size: CanvasRenderSize) {
        // The display link owns the drawable pool and presentation policy.
        // Setting maximumDrawableCount after attaching it raises an Objective-C
        // exception, aborting pointer/scroll handling before the frame can wake.
        // Configure only our rendering properties, and avoid unchanged writes.
        if layer.device !== pipelines.device { layer.device = pipelines.device }
        if layer.pixelFormat != .bgra8Unorm { layer.pixelFormat = .bgra8Unorm }
        if !layer.framebufferOnly { layer.framebufferOnly = true }
        if layer.isOpaque { layer.isOpaque = false }
        if layer.colorspace?.name != CGColorSpace.sRGB {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        if layer.drawableSize != size.size { layer.drawableSize = size.size }
    }

    /// No waits, readbacks, snapshots, or per-frame image allocation in the live path.
    @discardableResult
    func render(_ frame: CanvasFrame, to drawable: CAMetalDrawable) -> Bool {
        guard let slot = flight.acquire() else { return false }
        do {
            let command = try encode(frame, target: drawable.texture, slot: slot)
            let flight = flight
            command.addCompletedHandler { command in
                flight.finish(
                    slot, seconds: command.gpuEndTime - command.gpuStartTime, failed: command.status == .error)
            }
            command.commit()
            // CAMetalDisplayLink owns presentation timing. Timed present APIs
            // raise CAMetalDrawableInvalidOperation for its drawables. Submit
            // all GPU work first, then hand presentation back to the link.
            drawable.present()
            return true
        } catch {
            flight.finish(slot, failed: true)
            lastError = error.localizedDescription
            return false
        }
    }

    func releaseResources() {
        scene = nil
        paths = [nil, nil]
        headers = [CanvasCaptionTexture(), CanvasCaptionTexture()]
        coordinates = [CanvasCaptionTexture(), CanvasCaptionTexture()]
        notices = [CanvasCaptionTexture(), CanvasCaptionTexture()]
    }

    private func encode(_ frame: CanvasFrame, target: MTLTexture, slot: Int) throws -> MTLCommandBuffer {
        let crt = frame.effect == .crt
        guard
            let size = CanvasRenderSize(
                size: frame.size, scale: crt ? 1 : frame.scale,
                budget: crt ? 1_000_000 : CanvasRenderSize.pixelBudget)
        else {
            throw CanvasMetalPipelines.Failure.allocationFailed
        }
        if scene?.width != size.width || scene?.height != size.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            scene = pipelines.device.makeTexture(descriptor: descriptor)
        }
        guard let scene, let command = pipelines.queue.makeCommandBuffer() else {
            throw CanvasMetalPipelines.Failure.allocationFailed
        }
        // Preserve the 16-point grid at normal sizes. Bound instances for oversized offscreen surfaces.
        var stride = max(1, Int(ceil(sqrt(frame.size.width * frame.size.height / (16 * 16 * 24_000)))))
        while (Int(frame.size.width / CGFloat(16 * stride)) + 3)
            * (Int(frame.size.height / CGFloat(16 * stride)) + 3) > 32_768
        { stride += 1 }
        let spacing = CGFloat(16 * stride)
        let cols = Int(frame.size.width / spacing) + 3
        let rows = Int(frame.size.height / spacing) + 3
        let firstCol = (-1 - Int(frame.offset.width / spacing)) * stride
        let firstRow = (-1 - Int(frame.offset.height / spacing)) * stride
        let length = cols * rows * MemoryLayout<Float>.stride
        if paths[slot] == nil || paths[slot]!.length < length {
            paths[slot] = pipelines.device.makeBuffer(
                length: max(4096, (length + 4095) / 4096 * 4096), options: .storageModeShared)
        }
        guard let path = paths[slot] else { throw CanvasMetalPipelines.Failure.allocationFailed }
        frame.path.writeIntensities(
            into: UnsafeMutableBufferPointer(
                start: path.contents().assumingMemoryBound(to: Float.self),
                count: cols * rows), firstColumn: firstCol, firstRow: firstRow, columns: cols, rows: rows,
            stride: stride, at: frame.time)
        let fields = frame.edges.renderWeights(at: frame.time)
        var waves = frame.clicks.renderSources(at: frame.time, reduceMotion: frame.reduceMotion)
        let waveCount = waves.count
        if waves.isEmpty { waves.append(.init(geometry: .zero, timing: .zero)) }
        var f = Uniforms(
            viewport: SIMD4(Float(frame.size.width), Float(frame.size.height), Float(size.width), Float(size.height)),
            scroll: SIMD4(
                Float(frame.offset.width.truncatingRemainder(dividingBy: spacing)),
                Float(frame.offset.height.truncatingRemainder(dividingBy: spacing)), crt ? 1 : 0,
                frame.reduceMotion ? 1 : 0),
            accent: frame.color,
            appearance: SIMD4(
                frame.dark ? 1 : 0, Float(frame.coordinateOpacity), Float(frame.noticeOpacity), Float(frame.reveal)),
            power: SIMD4(
                Float(frame.power.width), Float(frame.power.height), Float(frame.power.brightness),
                Float(frame.signalTime)),
            grid: SIMD4(Float(cols), Float(rows), Float(stride), Float(firstCol)),
            dynamics: SIMD4(Float(firstRow), Float(frame.edges.sparseIntensity(at: frame.time)), Float(waveCount), 0))
        func pass(_ texture: MTLTexture, clear: MTLClearColor) -> MTLRenderPassDescriptor {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clear
            return pass
        }
        let backgroundLevel = frame.dark ? 0.055 : 0.94
        let clear =
            crt
            ? MTLClearColorMake(backgroundLevel, backgroundLevel, backgroundLevel, 1) : MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass(scene, clear: clear)) else {
            throw CanvasMetalPipelines.Failure.allocationFailed
        }
        encoder.setRenderPipelineState(pipelines.dots)
        encoder.setVertexBytes(&f, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(path, offset: 0, index: 1)
        fields.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        waves.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 3) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cols * rows)
        if frame.includesCaptions {
            updateCaptions(frame, slot: slot)
            encoder.setRenderPipelineState(pipelines.caption)
            func caption(_ cache: CanvasCaptionTexture, origin: CGPoint, opacity: Double) {
                guard let texture = cache.texture, opacity > 0 else { return }
                var rect = SIMD4<Float>(
                    Float(origin.x), Float(origin.y), Float(cache.logicalSize.width), Float(cache.logicalSize.height))
                var alpha = Float(opacity)
                encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            caption(headers[slot], origin: .zero, opacity: frame.noticeActive || frame.noticeOpacity > 0 ? 0 : 1)
            caption(
                coordinates[slot], origin: CGPoint(x: 20, y: crt ? 83 : 75),
                opacity: frame.noticeActive || frame.noticeOpacity > 0 ? 0 : frame.coordinateOpacity)
            caption(
                notices[slot],
                origin: CGPoint(
                    x: floor((frame.size.width - notices[slot].logicalSize.width) / 2),
                    y: frame.size.height - 38), opacity: frame.noticeOpacity)
        }
        encoder.endEncoding()
        guard
            let output = command.makeRenderCommandEncoder(
                descriptor: pass(target, clear: MTLClearColorMake(0, 0, 0, 0)))
        else {
            throw CanvasMetalPipelines.Failure.allocationFailed
        }
        output.setRenderPipelineState(pipelines.screen)
        output.setFragmentBytes(&f, length: MemoryLayout<Uniforms>.stride, index: 0)
        output.setFragmentTexture(scene, index: 0)
        output.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        output.endEncoding()
        return command
    }

    private func updateCaptions(_ frame: CanvasFrame, slot: Int) {
        let crt = frame.effect == .crt
        let scale: CGFloat = crt ? 1 : min(2, frame.scale)
        let primary = NSColor(calibratedWhite: frame.dark ? 0.92 : 0.12, alpha: 1)
        let secondary = NSColor(calibratedWhite: frame.dark ? 0.65 : 0.36, alpha: 1)
        let key = "\(crt)-\(frame.dark)-\(scale)"
        headers[slot].update(
            device: pipelines.device, key: key,
            size: CGSize(width: min(768, frame.size.width), height: 72), scale: scale
        ) {
            if crt {
                PixelCaption.draw("Try it", at: CGPoint(x: 20, y: 20), scale: 3, color: primary)
                PixelCaption.draw(
                    "Move your pointer here and try scrolling.", at: CGPoint(x: 20, y: 51), scale: 2, color: secondary)
            } else {
                ("Try it" as NSString).draw(
                    at: CGPoint(x: 20, y: 20),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: primary,
                    ])
                ("Move your pointer here and try scrolling." as NSString).draw(
                    at: CGPoint(x: 20, y: 44),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary,
                    ])
            }
        }
        coordinates[slot].update(
            device: pipelines.device, key: key + frame.coordinates,
            size: CGSize(width: 512, height: 24), scale: scale
        ) {
            if crt {
                PixelCaption.draw(frame.coordinates, at: .zero, scale: 2, color: secondary)
            } else {
                (frame.coordinates as NSString).draw(
                    at: .zero,
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: secondary,
                    ])
            }
        }
        if frame.noticeActive || frame.noticeOpacity > 0 {
            let text = "CRT unlocked. See Settings"
            notices[slot].update(
                device: pipelines.device, key: text,
                size: CGSize(width: PixelCaption.width(of: text, scale: 2), height: 24), scale: 1
            ) {
                PixelCaption.draw(text, at: .zero, scale: 2, color: .white)
            }
        }
    }
}
