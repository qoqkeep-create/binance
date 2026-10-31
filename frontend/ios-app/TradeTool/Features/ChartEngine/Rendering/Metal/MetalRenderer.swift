import Foundation
import Metal
import MetalKit
import simd

enum MetalRendererError: Error {
    case commandQueueUnavailable
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable
    case pipelineCreationFailed
    case resourceRingUnavailable
}

enum MetalDrawDisposition {
    case submitted
    case retryWhenResourceAvailable
    case skipped
}

struct MetalFrameCompletion: Sendable {
    let succeeded: Bool
    let failure: MetalCommandBufferFailureSummary?

    init(
        succeeded: Bool,
        failure: MetalCommandBufferFailureSummary? = nil
    ) {
        self.succeeded = succeeded
        self.failure = failure
    }
}

struct MetalOffscreenImage: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra8UnormSRGB: Data

    var visiblePixelHash: UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let visibleBytesPerRow = width * 4
        bgra8UnormSRGB.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let start = row * bytesPerRow
                for column in 0..<visibleBytesPerRow {
                    hash ^= UInt64(bytes[start + column])
                    hash &*= 1_099_511_628_211
                }
            }
        }
        return hash
    }

    var coloredPixelCount: Int {
        var count = 0
        bgra8UnormSRGB.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let start = row * bytesPerRow
                for pixel in 0..<width {
                    let offset = start + pixel * 4
                    if bytes[offset] != 0
                        || bytes[offset + 1] != 0
                        || bytes[offset + 2] != 0 {
                        count += 1
                    }
                }
            }
        }
        return count
    }
}

private struct MetalCandleInstance {
    var geometry: SIMD4<Float>
    var style: SIMD4<Float>

    init(
        _ instance: ChartCandleInstance,
        appliesTimelineTransform: Bool
    ) {
        geometry = SIMD4(
            instance.x,
            instance.openY,
            instance.highY,
            instance.lowY
        )
        style = SIMD4(
            instance.closeY,
            instance.halfBodyWidth,
            instance.isRising ? 1 : 0,
            appliesTimelineTransform ? 1 : 0
        )
    }
}

private struct MetalLineInstance {
    var geometry: SIMD4<Float>
    var style: SIMD4<Float>
    var color: SIMD4<Float>
    var flags: SIMD4<Float>

    init(
        _ instance: ChartLineSegmentInstance,
        timelineTransformMode: Float,
        appearance: ChartAppearance
    ) {
        geometry = SIMD4(
            instance.start.x,
            instance.start.y,
            instance.end.x,
            instance.end.y
        )
        style = SIMD4(
            instance.width,
            instance.dashLength,
            instance.gapLength,
            instance.dashPhase
        )
        color = instance.color.resolved(for: appearance).metalValue
        flags = SIMD4(
            timelineTransformMode,
            instance.antialias ? 1 : 0,
            0,
            0
        )
    }
}

private struct MetalBarInstance {
    var geometry: SIMD4<Float>
    var color: SIMD4<Float>
    var flags: SIMD4<Float>

    init(
        _ instance: ChartBarInstance,
        appliesTimelineTransform: Bool,
        appearance: ChartAppearance
    ) {
        geometry = SIMD4(
            instance.left,
            instance.top,
            instance.right,
            instance.bottom
        )
        color = instance.color.resolved(for: appearance).metalValue
        flags = SIMD4(
            appliesTimelineTransform ? 1 : 0,
            instance.cornerRadius,
            0,
            0
        )
    }
}

private struct MetalGlyphInstance {
    var geometry: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var flags: SIMD4<Float>

    init(
        _ instance: ChartGlyphInstance,
        appliesTimelineTransform: Bool,
        appearance: ChartAppearance
    ) {
        geometry = SIMD4(
            instance.left,
            instance.top,
            instance.right,
            instance.bottom
        )
        uv = SIMD4(
            instance.uvLeft,
            instance.uvTop,
            instance.uvRight,
            instance.uvBottom
        )
        color = instance.color.resolved(for: appearance).metalValue
        flags = SIMD4(
            appliesTimelineTransform ? 1 : 0,
            instance.timelineAnchorX ?? instance.left,
            0,
            0
        )
    }
}

private struct MetalChartUniforms {
    var viewportSize: SIMD2<Float>
    var translationAndScale: SIMD2<Float>
    var horizontalPlotBounds: SIMD2<Float>
    var timelineBodyStyle: SIMD2<Float>
    var positiveColor: SIMD4<Float>
    var negativeColor: SIMD4<Float>
}

private struct MetalSceneLayout {
    let candleOffset: Int
    let candleCount: Int
    let lineOffset: Int
    let lineCount: Int
    let barOffset: Int
    let barCount: Int
    let glyphOffset: Int
    let glyphCount: Int
    let requiredBytes: Int
    let glyphAtlas: ChartGlyphAtlasSnapshot?
    let drawRanges: [MetalSceneDrawRange]
}

private struct MetalSceneDrawRange {
    let candles: Range<Int>
    let lines: Range<Int>
    let bars: Range<Int>
    let glyphs: Range<Int>
}

private final class MetalStaticSceneResources {
    let appearance: ChartAppearance
    let revision: UInt64
    let buffer: MTLBuffer
    let layout: MetalSceneLayout

    init(
        revision: UInt64,
        appearance: ChartAppearance,
        buffer: MTLBuffer,
        layout: MetalSceneLayout
    ) {
        self.revision = revision
        self.appearance = appearance
        self.buffer = buffer
        self.layout = layout
    }
}

private extension ChartColor {
    var metalValue: SIMD4<Float> {
        linearRGBA
    }
}

private extension MTLCommandBufferStatus {
    var chartDescription: String {
        switch self {
        case .notEnqueued:
            "notEnqueued"
        case .enqueued:
            "enqueued"
        case .committed:
            "committed"
        case .scheduled:
            "scheduled"
        case .completed:
            "completed"
        case .error:
            "error"
        @unknown default:
            "unknown"
        }
    }
}

final class MetalRenderer {
    private static let maximumCandleInstances = 4_096
    private static let maximumLineInstances = 16_384
    private static let maximumBarInstances = 4_096
    private static let maximumGlyphInstances = 8_192
    private static let maximumFrameBytes = 2_097_152
    private static let bufferAlignment = 256
    private static let maximumOffscreenDimension = 4_096

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let commandQueue: MTLCommandQueue
    private let candlePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let barPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let dynamicRing: MetalResourceRing
    private let glyphTextureCache = MetalGlyphTextureCache()
    let health: MetalRendererHealth

    private var staticResources: MetalStaticSceneResources?

    init(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        health: MetalRendererHealth = MetalRendererHealth()
    ) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.health = health

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        commandQueue.label = "Chart command queue"

        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.shaderLibraryUnavailable
        }
        candlePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "chartCandleVertex",
            fragmentName: "chartCandleFragment",
            pixelFormat: pixelFormat,
            label: "Chart candle pipeline"
        )
        linePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "chartLineVertex",
            fragmentName: "chartLineFragment",
            pixelFormat: pixelFormat,
            label: "Chart line pipeline"
        )
        barPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "chartBarVertex",
            fragmentName: "chartBarFragment",
            pixelFormat: pixelFormat,
            label: "Chart bar pipeline"
        )
        glyphPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "chartGlyphVertex",
            fragmentName: "chartGlyphFragment",
            pixelFormat: pixelFormat,
            label: "Chart glyph pipeline"
        )

        guard let dynamicRing = MetalResourceRing(
            device: device,
            capacityPerSlot: Self.maximumFrameBytes
        ) else {
            throw MetalRendererError.resourceRingUnavailable
        }
        self.dynamicRing = dynamicRing
    }

    @discardableResult
    func draw(
        state: RenderState,
        in view: MTKView,
        completion: @escaping @Sendable (
            MetalFrameCompletion
        ) -> Void
    ) -> MetalDrawDisposition {
        updateStaticBufferIfNeeded(state.staticScene, appearance: state.appearance)

        let dynamicBatches = Self.dynamicBatches(for: state)
        guard let liveLayout = makeLayout(
            batches: dynamicBatches,
            overlayBatchCount:
                state.interaction.crosshair?.batches.count ?? 0
        ) else {
            health.recordBufferCapacityRejection()
            return .skipped
        }
        guard let lease = dynamicRing.acquire(
            requiredBytes: liveLayout.requiredBytes
        ) else {
            health.recordGPUBusySkip()
            return .retryWhenResourceAvailable
        }
        write(
            batches: dynamicBatches,
            to: lease.buffer,
            layout: liveLayout,
            appearance: state.appearance
        )

        let staticTexture = textureIfNeeded(
            layout: staticResources?.layout
        )
        let liveTexture = textureIfNeeded(layout: liveLayout)
        guard staticTexture.isUsable,
              liveTexture.isUsable else {
            dynamicRing.releaseWithoutSubmission(lease)
            health.recordBufferCapacityRejection()
            return .skipped
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            dynamicRing.releaseWithoutSubmission(lease)
            return .skipped
        }
        commandBuffer.label = "Chart frame \(state.revision)"

        guard let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            dynamicRing.releaseWithoutSubmission(lease)
            health.recordNilDrawableSkip()
            return .skipped
        }
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = Self.clearColor(for: state.appearance)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPass
        ) else {
            dynamicRing.releaseWithoutSubmission(lease)
            return .skipped
        }
        encoder.label = "Chart scene encoder"
        setUniforms(
            encoder: encoder,
            viewportWidth: view.drawableSize.width,
            viewportHeight: view.drawableSize.height,
            interaction: state.interaction,
            horizontalPlotBounds:
                state.staticScene.horizontalPlotBounds,
            appearance: state.appearance
        )

        if let staticResources {
            encode(
                buffer: staticResources.buffer,
                layout: staticResources.layout,
                glyphTexture: staticTexture.texture,
                encoder: encoder
            )
        }
        encode(
            buffer: lease.buffer,
            layout: liveLayout,
            glyphTexture: liveTexture.texture,
            encoder: encoder
        )
        encoder.endEncoding()

        let revision = state.revision
        let liveRevision = state.liveTail.revision
        let liveReadyTime = state.liveTail.readyTime
        let readyTime = state.readyTime
        let submittedTime =
            ProcessInfo.processInfo.systemUptime
        let submissionContext = health.recordSubmitted()
#if targetEnvironment(simulator)
        // The simulator SDK does not expose MTLDrawable's presentation callback.
        // Simulator completion keeps tests usable; only physical-device
        // presentedTime is accepted as receive-to-present telemetry.
#else
        drawable.addPresentedHandler { [health] drawable in
            health.recordPresented(
                revision: revision,
                liveRevision: liveRevision,
                liveReadyTime: liveReadyTime,
                presentedTime: drawable.presentedTime,
                readyTime: readyTime,
                submittedTime: submittedTime,
                submissionContext: submissionContext
            )
        }
#endif
        commandBuffer.addCompletedHandler {
            [dynamicRing, health] commandBuffer in
            let succeeded = commandBuffer.status == .completed
            let failure = succeeded
                ? nil
                : MetalCommandBufferFailureSummary(
                    status: commandBuffer.status.chartDescription,
                    error: commandBuffer.error
                )
            dynamicRing.complete(lease, succeeded: succeeded)
            health.recordCommandCompleted(
                succeeded: succeeded,
                failure: failure
            )
#if targetEnvironment(simulator)
            if succeeded {
                health.recordPresented(
                    revision: revision,
                    liveRevision: liveRevision,
                    liveReadyTime: liveReadyTime,
                    presentedTime:
                        ProcessInfo.processInfo.systemUptime,
                    readyTime: readyTime,
                    submittedTime: submittedTime,
                    submissionContext: submissionContext
                )
            }
#endif
            completion(MetalFrameCompletion(
                succeeded: succeeded,
                failure: failure
            ))
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return .submitted
    }

    func handleMemoryWarning() {
        staticResources = nil
        glyphTextureCache.removeAll()
        health.recordMemoryWarning()
    }

    func renderOffscreen(
        state: RenderState,
        width: Int,
        height: Int
    ) -> MetalOffscreenImage? {
        guard width > 0,
              height > 0,
              width <= Self.maximumOffscreenDimension,
              height <= Self.maximumOffscreenDimension,
              let staticPacked = makePackedBuffer(
                batches: state.staticScene.batches,
                label: "Chart offscreen static",
                appearance: state.appearance
              ),
              let livePacked = makePackedBuffer(
                batches: Self.dynamicBatches(for: state),
                overlayBatchCount:
                    state.interaction.crosshair?.batches.count ?? 0,
                label: "Chart offscreen live",
                appearance: state.appearance
              ) else {
            return nil
        }

        let staticTexture = textureIfNeeded(
            layout: staticPacked.layout
        )
        let liveTexture = textureIfNeeded(
            layout: livePacked.layout
        )
        guard staticTexture.isUsable,
              liveTexture.isUsable else {
            return nil
        }

        let textureDescriptor = MTLTextureDescriptor
            .texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(
            descriptor: textureDescriptor
        ) else {
            return nil
        }
        target.label = "Chart offscreen target"

        let visibleBytesPerRow = width * 4
        guard let bytesPerRow = Self.aligned(
            visibleBytesPerRow,
            to: 256
        ) else {
            return nil
        }
        let (readbackLength, overflow) = bytesPerRow
            .multipliedReportingOverflow(by: height)
        guard !overflow,
              let readback = device.makeBuffer(
                length: readbackLength,
                options: .storageModeShared
              ),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return nil
        }
        readback.label = "Chart offscreen readback"
        commandBuffer.label = "Chart offscreen frame"

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = Self.clearColor(for: state.appearance)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPass
        ) else {
            return nil
        }
        encoder.label = "Chart offscreen scene encoder"
        setUniforms(
            encoder: encoder,
            viewportWidth: Double(width),
            viewportHeight: Double(height),
            interaction: state.interaction,
            horizontalPlotBounds:
                state.staticScene.horizontalPlotBounds,
            appearance: state.appearance
        )
        encode(
            buffer: staticPacked.buffer,
            layout: staticPacked.layout,
            glyphTexture: staticTexture.texture,
            encoder: encoder
        )
        encode(
            buffer: livePacked.buffer,
            layout: livePacked.layout,
            glyphTexture: liveTexture.texture,
            encoder: encoder
        )
        encoder.endEncoding()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(
                width: width,
                height: height,
                depth: 1
            ),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: readbackLength
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            return nil
        }

        return MetalOffscreenImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bgra8UnormSRGB: Data(
                bytes: readback.contents(),
                count: readbackLength
            )
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String,
        pixelFormat: MTLPixelFormat,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(
                name: fragmentName
              ) else {
            throw MetalRendererError.shaderFunctionUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor =
            .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor =
            .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor =
            .oneMinusSourceAlpha
        do {
            return try device.makeRenderPipelineState(
                descriptor: descriptor
            )
        } catch {
            throw MetalRendererError.pipelineCreationFailed
        }
    }

    static func dynamicBatches(
        for state: RenderState
    ) -> [ChartRenderBatch] {
        let liveBatches: [ChartRenderBatch]
        if state.interaction.crosshair == nil {
            liveBatches = state.liveTail.batches
        } else {
            liveBatches = state.liveTail.batches.filter {
                $0.interactionVisibility
                    != .hiddenWhileCrosshairIsActive
            }
        }
        return liveBatches
            + (state.interaction.crosshair?.batches ?? [])
    }

    private func updateStaticBufferIfNeeded(
        _ scene: StaticSceneSnapshot,
        appearance: ChartAppearance
    ) {
        guard staticResources?.revision != scene.revision
            || staticResources?.appearance != appearance else {
            return
        }
        guard let packed = makePackedBuffer(
            batches: scene.batches,
            label: "Chart stable scene",
            appearance: appearance
        ) else {
            health.recordBufferCapacityRejection()
            return
        }
        staticResources = MetalStaticSceneResources(
            revision: scene.revision,
            appearance: appearance,
            buffer: packed.buffer,
            layout: packed.layout
        )
    }

    private func makePackedBuffer(
        batches: [ChartRenderBatch],
        overlayBatchCount: Int = 0,
        label: String,
        appearance: ChartAppearance
    ) -> (buffer: MTLBuffer, layout: MetalSceneLayout)? {
        guard let layout = makeLayout(
                batches: batches,
                overlayBatchCount: overlayBatchCount
              ),
              let buffer = device.makeBuffer(
                length: max(1, layout.requiredBytes),
                options: .storageModeShared
              ) else {
            return nil
        }
        buffer.label = label
        write(batches: batches, to: buffer, layout: layout, appearance: appearance)
        return (buffer, layout)
    }

    private func makeLayout(
        batches: [ChartRenderBatch],
        overlayBatchCount: Int = 0
    ) -> MetalSceneLayout? {
        var candleCount = 0
        var lineCount = 0
        var barCount = 0
        var glyphCount = 0
        var glyphAtlas: ChartGlyphAtlasSnapshot?
        var contentCounts = (candles: 0, lines: 0, bars: 0, glyphs: 0)

        for (index, batch) in batches.enumerated() {
            if index == batches.count - overlayBatchCount {
                contentCounts = (
                    candleCount, lineCount, barCount, glyphCount
                )
            }
            guard Self.accumulate(
                &candleCount,
                batch.storage.candleInstances.count
            ),
            Self.accumulate(
                &lineCount,
                batch.storage.lineSegments.count
            ),
            Self.accumulate(
                &barCount,
                batch.storage.barInstances.count
            ),
            Self.accumulate(
                &glyphCount,
                batch.storage.glyphInstances.count
            ) else {
                return nil
            }

            if !batch.storage.glyphInstances.isEmpty {
                guard let batchAtlas = batch.storage.glyphAtlas else {
                    return nil
                }
                if let glyphAtlas,
                   glyphAtlas.revision != batchAtlas.revision {
                    return nil
                }
                glyphAtlas = batchAtlas
            }
        }

        if overlayBatchCount == 0 {
            contentCounts = (candleCount, lineCount, barCount, glyphCount)
        }
        var drawRanges = [MetalSceneDrawRange(
            candles: 0..<contentCounts.candles,
            lines: 0..<contentCounts.lines,
            bars: 0..<contentCounts.bars,
            glyphs: 0..<contentCounts.glyphs
        )]
        if overlayBatchCount > 0 {
            // Finish every content primitive before painting the crosshair.
            // Its white labels must also cover latest-price lines and glyphs.
            drawRanges.append(MetalSceneDrawRange(
                candles: contentCounts.candles..<candleCount,
                lines: contentCounts.lines..<lineCount,
                bars: contentCounts.bars..<barCount,
                glyphs: contentCounts.glyphs..<glyphCount
            ))
        }

        guard candleCount <= Self.maximumCandleInstances,
              lineCount <= Self.maximumLineInstances,
              barCount <= Self.maximumBarInstances,
              glyphCount <= Self.maximumGlyphInstances else {
            return nil
        }

        var offset = 0
        let candleOffset = offset
        guard let afterCandles = Self.advance(
            offset,
            count: candleCount,
            stride: MemoryLayout<MetalCandleInstance>.stride
        ),
        let lineOffset = Self.aligned(
            afterCandles,
            to: Self.bufferAlignment
        ),
        let afterLines = Self.advance(
            lineOffset,
            count: lineCount,
            stride: MemoryLayout<MetalLineInstance>.stride
        ),
        let barOffset = Self.aligned(
            afterLines,
            to: Self.bufferAlignment
        ),
        let afterBars = Self.advance(
            barOffset,
            count: barCount,
            stride: MemoryLayout<MetalBarInstance>.stride
        ),
        let glyphOffset = Self.aligned(
            afterBars,
            to: Self.bufferAlignment
        ),
        let requiredBytes = Self.advance(
            glyphOffset,
            count: glyphCount,
            stride: MemoryLayout<MetalGlyphInstance>.stride
        ),
        requiredBytes <= Self.maximumFrameBytes else {
            return nil
        }
        offset = requiredBytes

        return MetalSceneLayout(
            candleOffset: candleOffset,
            candleCount: candleCount,
            lineOffset: lineOffset,
            lineCount: lineCount,
            barOffset: barOffset,
            barCount: barCount,
            glyphOffset: glyphOffset,
            glyphCount: glyphCount,
            requiredBytes: offset,
            glyphAtlas: glyphAtlas,
            drawRanges: drawRanges
        )
    }

    private func write(
        batches: [ChartRenderBatch],
        to buffer: MTLBuffer,
        layout: MetalSceneLayout,
        appearance: ChartAppearance
    ) {
        if layout.candleCount > 0 {
            let pointer = buffer.contents()
                .advanced(by: layout.candleOffset)
                .bindMemory(
                    to: MetalCandleInstance.self,
                    capacity: layout.candleCount
                )
            var index = 0
            for batch in batches {
                let appliesTimelineTransform =
                    batch.coordinateSpace == .timeline
                for instance in batch.storage.candleInstances {
                    guard index < layout.candleCount else {
                        break
                    }
                    pointer[index] = MetalCandleInstance(
                        instance,
                        appliesTimelineTransform:
                            appliesTimelineTransform
                    )
                    index += 1
                }
            }
        }

        if layout.lineCount > 0 {
            let pointer = buffer.contents()
                .advanced(by: layout.lineOffset)
                .bindMemory(
                    to: MetalLineInstance.self,
                    capacity: layout.lineCount
                )
            var index = 0
            for batch in batches {
                let timelineTransformMode: Float = switch
                    batch.coordinateSpace {
                case .timeline:
                    1
                case .latestPriceTimelineLine:
                    2
                case .fixed, .latestPrice:
                    0
                }
                for instance in batch.storage.lineSegments {
                    guard index < layout.lineCount else {
                        break
                    }
                    pointer[index] = MetalLineInstance(
                        instance,
                        timelineTransformMode:
                            timelineTransformMode,
                        appearance: appearance
                    )
                    index += 1
                }
            }
        }

        if layout.barCount > 0 {
            let pointer = buffer.contents()
                .advanced(by: layout.barOffset)
                .bindMemory(
                    to: MetalBarInstance.self,
                    capacity: layout.barCount
                )
            var index = 0
            for batch in batches {
                let appliesTimelineTransform =
                    batch.coordinateSpace == .timeline
                for instance in batch.storage.barInstances {
                    guard index < layout.barCount else {
                        break
                    }
                    pointer[index] = MetalBarInstance(
                        instance,
                        appliesTimelineTransform:
                            appliesTimelineTransform,
                        appearance: appearance
                    )
                    index += 1
                }
            }
        }

        if layout.glyphCount > 0 {
            let pointer = buffer.contents()
                .advanced(by: layout.glyphOffset)
                .bindMemory(
                    to: MetalGlyphInstance.self,
                    capacity: layout.glyphCount
                )
            var index = 0
            for batch in batches {
                let appliesTimelineTransform =
                    batch.coordinateSpace == .timeline
                for instance in batch.storage.glyphInstances {
                    guard index < layout.glyphCount else {
                        break
                    }
                    pointer[index] = MetalGlyphInstance(
                        instance,
                        appliesTimelineTransform:
                            appliesTimelineTransform,
                        appearance: appearance
                    )
                    index += 1
                }
            }
        }
    }

    private static func clearColor(for appearance: ChartAppearance) -> MTLClearColor {
        let color = ChartColor.chartBackground.resolved(for: appearance).linearRGBA
        return MTLClearColor(
            red: Double(color.x),
            green: Double(color.y),
            blue: Double(color.z),
            alpha: Double(color.w)
        )
    }

    private func setUniforms(
        encoder: MTLRenderCommandEncoder,
        viewportWidth: Double,
        viewportHeight: Double,
        interaction: InteractionSnapshot,
        horizontalPlotBounds: ChartHorizontalPlotBounds?,
        appearance: ChartAppearance
    ) {
        let plotBounds = horizontalPlotBounds.map {
            SIMD2($0.left, $0.right)
        } ?? SIMD2(
            -Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var uniforms = MetalChartUniforms(
            viewportSize: SIMD2(
                Float(viewportWidth),
                Float(viewportHeight)
            ),
            translationAndScale: SIMD2(
                Float(interaction.translationX),
                Float(interaction.scaleX)
            ),
            horizontalPlotBounds: plotBounds,
            timelineBodyStyle: SIMD2(
                Float(
                    interaction.candleHalfBodyWidthPixels
                        ?? 0
                ),
                Float(
                    interaction.candleHalfWickWidthPixels
                        ?? 0.5
                )
            ),
            positiveColor: ChartColor.positive.resolved(for: appearance).metalValue,
            negativeColor: ChartColor.negative.resolved(for: appearance).metalValue
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<MetalChartUniforms>.stride,
            index: 1
        )
    }

    private func encode(
        buffer: MTLBuffer,
        layout: MetalSceneLayout,
        glyphTexture: MTLTexture?,
        encoder: MTLRenderCommandEncoder
    ) {
        for range in layout.drawRanges {
            encode(
                buffer: buffer,
                layout: layout,
                range: range,
                glyphTexture: glyphTexture,
                encoder: encoder
            )
        }
    }

    private func encode(
        buffer: MTLBuffer,
        layout: MetalSceneLayout,
        range: MetalSceneDrawRange,
        glyphTexture: MTLTexture?,
        encoder: MTLRenderCommandEncoder
    ) {
        if !range.bars.isEmpty {
            encoder.setRenderPipelineState(barPipeline)
            encoder.setVertexBuffer(
                buffer,
                offset: layout.barOffset
                    + range.bars.lowerBound
                        * MemoryLayout<MetalBarInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: range.bars.count
            )
        }

        if !range.candles.isEmpty {
            encoder.setRenderPipelineState(candlePipeline)
            encoder.setVertexBuffer(
                buffer,
                offset: layout.candleOffset
                    + range.candles.lowerBound
                        * MemoryLayout<MetalCandleInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 12,
                instanceCount: range.candles.count
            )
        }

        if !range.lines.isEmpty {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(
                buffer,
                offset: layout.lineOffset
                    + range.lines.lowerBound
                        * MemoryLayout<MetalLineInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: range.lines.count
            )
        }

        if !range.glyphs.isEmpty,
           let glyphTexture {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(
                buffer,
                offset: layout.glyphOffset
                    + range.glyphs.lowerBound
                        * MemoryLayout<MetalGlyphInstance>.stride,
                index: 0
            )
            encoder.setFragmentTexture(glyphTexture, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: range.glyphs.count
            )
        }
    }

    private func textureIfNeeded(
        layout: MetalSceneLayout?
    ) -> (texture: MTLTexture?, isUsable: Bool) {
        guard let layout,
              layout.glyphCount > 0 else {
            return (nil, true)
        }
        guard let atlas = layout.glyphAtlas,
              let texture = glyphTextureCache.texture(
                for: atlas,
                device: device
              ) else {
            return (nil, false)
        }
        return (texture, true)
    }

    private static func advance(
        _ offset: Int,
        count: Int,
        stride: Int
    ) -> Int? {
        let (bytes, multiplyOverflow) = count
            .multipliedReportingOverflow(by: stride)
        let (result, addOverflow) = offset
            .addingReportingOverflow(bytes)
        return multiplyOverflow || addOverflow ? nil : result
    }

    private static func accumulate(
        _ total: inout Int,
        _ addition: Int
    ) -> Bool {
        let (result, overflow) = total.addingReportingOverflow(
            addition
        )
        guard !overflow else {
            return false
        }
        total = result
        return true
    }

    private static func aligned(
        _ value: Int,
        to alignment: Int
    ) -> Int? {
        guard value >= 0,
              alignment > 0 else {
            return nil
        }
        let remainder = value % alignment
        guard remainder != 0 else {
            return value
        }
        let (result, overflow) = value.addingReportingOverflow(
            alignment - remainder
        )
        return overflow ? nil : result
    }
}
