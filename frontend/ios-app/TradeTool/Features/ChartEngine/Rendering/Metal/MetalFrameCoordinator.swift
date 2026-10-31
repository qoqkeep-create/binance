import MetalKit
import QuartzCore
import UIKit

@MainActor
final class MetalFrameCoordinator: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private let mailbox: LatestRenderStateMailbox
    private var renderer: MetalRenderer?
    private let rendererFactory: () throws -> MetalRenderer
    private let health: MetalRendererHealth
    private let onRendererStopped: (String) -> Void
    private var onInteractionFrame:
        ((CFTimeInterval) -> Void)?
    private var displayLink: CADisplayLink?
    private var currentState: RenderState?
    private var retryWhenResourceAvailable = false
    private var rendererGeneration: UInt64 = 1
    private var failurePolicy = MetalRendererFailurePolicy()
    private var isStopped = false
    private var isInteractionRequested = false
    private(set) var isSuspended = false
    private(set) var isInteractionActive = false

    init(
        view: MTKView,
        renderer: MetalRenderer,
        rendererFactory: @escaping () throws -> MetalRenderer,
        onRendererStopped: @escaping (String) -> Void,
        onInteractionFrame:
            ((CFTimeInterval) -> Void)? = nil,
        mailbox: LatestRenderStateMailbox =
            LatestRenderStateMailbox()
    ) {
        self.view = view
        self.renderer = renderer
        self.rendererFactory = rendererFactory
        health = renderer.health
        self.onRendererStopped = onRendererStopped
        self.onInteractionFrame = onInteractionFrame
        self.mailbox = mailbox
        super.init()
        view.delegate = self
        updateHealthPresentationContext()
    }

    func submit(_ state: RenderState) {
        mailbox.publish(state)
        guard !isInteractionActive,
              !isSuspended,
              !isStopped else {
            return
        }
        view?.setNeedsDisplay()
    }

    func startInteractionFrames() {
        guard !isStopped else {
            return
        }
        isInteractionRequested = true
        activateInteractionFramesIfPossible()
    }

    func stopInteractionFrames() {
        isInteractionRequested = false
        deactivateInteractionFrames()
    }

    func suspend() {
        guard !isStopped, !isSuspended else {
            return
        }
        isSuspended = true
        deactivateInteractionFrames()
        updateHealthPresentationContext()
        view?.isPaused = true
        view?.releaseDrawables()
        health.recordRendererSuspend()
    }

    func resume() {
        guard !isStopped, isSuspended else {
            return
        }
        isSuspended = false
        if isInteractionRequested {
            activateInteractionFramesIfPossible()
        } else {
            updateHealthPresentationContext()
            view?.isPaused = true
            view?.enableSetNeedsDisplay = true
            view?.setNeedsDisplay()
        }
        health.recordRendererResume()
    }

    func dispose() {
        isStopped = true
        isSuspended = true
        stopInteractionFrames()
        view?.delegate = nil
        view = nil
        currentState = nil
        renderer = nil
        onInteractionFrame = nil
        retryWhenResourceAvailable = false
        updateHealthPresentationContext()
    }

    func handleMemoryWarning() {
        renderer?.handleMemoryWarning()
        guard !isStopped, !isSuspended else {
            return
        }
        view?.setNeedsDisplay()
    }

#if DEBUG
    var diagnosticIsStopped: Bool {
        isStopped
    }

    var diagnosticIsInteractionActive: Bool {
        isInteractionActive
    }

    func diagnosticInjectCommandFailure() {
        guard !isStopped else {
            return
        }
        health.recordSimulatedCommandBufferError()
        frameDidComplete(
            MetalFrameCompletion(succeeded: false),
            generation: rendererGeneration
        )
    }
#endif

    func draw(in view: MTKView) {
        if let latest = mailbox.consumeLatest() {
            currentState = latest
        }
        guard let currentState,
              let renderer,
              !isSuspended,
              !isStopped else {
            return
        }

        let generation = rendererGeneration
        let disposition = autoreleasepool {
            renderer.draw(
                state: currentState,
                in: view,
                completion: { [weak self] completion in
                    Task { @MainActor [weak self] in
                        self?.frameDidComplete(
                            completion,
                            generation: generation
                        )
                    }
                }
            )
        }

        switch disposition {
        case .submitted:
            retryWhenResourceAvailable = false
        case .retryWhenResourceAvailable:
            retryWhenResourceAvailable = true
        case .skipped:
            break
        }
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        guard size.width > 0, size.height > 0 else {
            return
        }
        guard !isSuspended, !isStopped else {
            return
        }
        view.setNeedsDisplay()
    }

    @objc
    private func displayLinkDidFire(_ link: CADisplayLink) {
        guard isInteractionActive,
              !isSuspended,
              !isStopped,
              view?.window != nil else {
            return
        }
        onInteractionFrame?(link.targetTimestamp)
        view?.draw()
    }

    private func resourceDidBecomeAvailable() {
        guard retryWhenResourceAvailable,
              !isStopped,
              !isSuspended,
              !isInteractionActive,
              view?.window != nil else {
            return
        }
        view?.setNeedsDisplay()
    }

    private func frameDidComplete(
        _ completion: MetalFrameCompletion,
        generation: UInt64
    ) {
        guard generation == rendererGeneration,
              !isStopped else {
            return
        }

        if completion.succeeded {
            failurePolicy.recordSuccess()
            resourceDidBecomeAvailable()
            return
        }

        retryWhenResourceAvailable = false
        switch failurePolicy.recordFailure(
            at: ProcessInfo.processInfo.systemUptime
        ) {
        case .rebuild:
            rebuildRenderer()
        case .stop:
            stopRenderer(
                message: "K线 GPU 连续渲染失败，请重新进入页面"
            )
        }
    }

    private func rebuildRenderer() {
        health.recordRendererRebuildAttempt()
        do {
            let replacement = try rendererFactory()
            renderer = replacement
            rendererGeneration &+= 1
            health.recordRendererRebuildSuccess()
            view?.setNeedsDisplay()
        } catch {
            stopRenderer(
                message: "K线渲染器重建失败，请重新进入页面"
            )
        }
    }

    private func stopRenderer(message: String) {
        guard !isStopped else {
            return
        }
        isStopped = true
        renderer = nil
        retryWhenResourceAvailable = false
        isSuspended = true
        stopInteractionFrames()
        updateHealthPresentationContext()
        view?.releaseDrawables()
        health.recordRendererCircuitBreakerStop()
        onRendererStopped(message)
    }

    private func activateInteractionFramesIfPossible() {
        guard isInteractionRequested,
              !isInteractionActive,
              !isSuspended,
              !isStopped else {
            return
        }
        isInteractionActive = true
        updateHealthPresentationContext()
        view?.isPaused = true
        view?.enableSetNeedsDisplay = false

        let link = CADisplayLink(
            target: self,
            selector: #selector(displayLinkDidFire)
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func deactivateInteractionFrames() {
        guard isInteractionActive else {
            return
        }
        isInteractionActive = false
        updateHealthPresentationContext()
        displayLink?.invalidate()
        displayLink = nil
        view?.isPaused = true
        view?.enableSetNeedsDisplay = true

        if !isSuspended,
           !isStopped,
           mailbox.hasPendingState {
            view?.setNeedsDisplay()
        }
    }

    deinit {
        displayLink?.invalidate()
    }

    private func updateHealthPresentationContext() {
        health.updateRendererPresentationContext(
            isSuspended: isSuspended,
            isInteractionActive: isInteractionActive
        )
    }
}
