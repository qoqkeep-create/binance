import AVKit
import SwiftUI

struct FloatingPiPSnapshot: Equatable {
  var positions: [FloatingPosition] = []
  var selectedIndex = 0
  var updatedAt: Date?
  var status = "正在同步…"

  func presentation(at now: Date, cyclingSince: Date?, paused: Bool) -> FloatingPiPPresentation {
    let offset = cyclingSince.map { max(0, Int(now.timeIntervalSince($0) / 5)) } ?? 0
    let index = positions.isEmpty ? 0 : (max(0, selectedIndex) + offset) % positions.count
    let position = positions.isEmpty ? nil : positions[index]
    let stale = updatedAt.map { now.timeIntervalSince($0) > 12 } ?? true
    let available = !paused && !stale
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let timestamp = updatedAt.map { formatter.string(from: $0) }
    let footer: String
    if paused { footer = "已暂停 · 点击播放恢复" }
    else if !positions.isEmpty && stale { footer = "更新延迟 · " + (timestamp ?? "--") }
    else { footer = timestamp.map { "更新 " + $0 } ?? status }
    return FloatingPiPPresentation(
      title: position?.symbol ?? "持仓浮窗", side: position.map { $0.isShort ? "空" : "多" } ?? "",
      price: available ? position?.priceText ?? "--" : "--",
      profit: available ? position?.profitText ?? "--" : "--",
      loss: position?.profit.map { $0 < 0 } ?? false,
      page: positions.count > 1 ? "\(index + 1)/\(positions.count)" : "", footer: footer)
  }
}

struct FloatingPiPPresentation: Equatable {
  let title: String
  let side: String
  let price: String
  let profit: String
  let loss: Bool
  let page: String
  let footer: String
}

/// The system owns the external window; no private overlay or silent audio is used.
@MainActor
final class FloatingPositionsPiP: NSObject, ObservableObject,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  @Published private(set) var isActive = false
  @Published private(set) var isStarting = false
  @Published private(set) var isPaused = false
  @Published var notice: String?
  var onSystemClose: (() -> Void)?
  var keepsUpdating: Bool { (isActive || isStarting) && !isPaused }
  private nonisolated let playback = FloatingPiPPlaybackState()
  private var controller: AVPictureInPictureController?
  private weak var sourceView: FloatingPiPSourceView?
  private var possibility: NSKeyValueObservation?
  private var ticker: Timer?
  private var startDeadline: Task<Void, Never>?
  private var startIssued = false
  private var restoringInline = false
  private var userClose = true
  private var ownsAudioSession = false
  private var isPreparedForAutomaticStart = false
  private var startedAt: Date?
  private var snapshot = FloatingPiPSnapshot()

  func attach(_ view: FloatingPiPSourceView) {
    sourceView = view
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
    let pip: AVPictureInPictureController
    if let existing = controller {
      existing.contentSource = source
      pip = existing
    } else {
      pip = AVPictureInPictureController(contentSource: source)
    }
    controller = pip
    pip.delegate = self
    pip.canStartPictureInPictureAutomaticallyFromInline = isPreparedForAutomaticStart
    possibility = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor in self?.startWhenReady() }
    }
    view.onWindowChange = { [weak self] in self?.render(); self?.startWhenReady() }
    render()
  }

  func update(_ snapshot: FloatingPiPSnapshot) {
    self.snapshot = snapshot
    render()
  }

  @discardableResult
  func prepareForAutomaticStart(reportFailure: Bool = false) -> Bool {
    if isPreparedForAutomaticStart { return true }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      if reportFailure { notice = "此设备暂不支持画中画，仍可使用 App 内浮窗。" }
      return false
    }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try audio.setActive(true)
      ownsAudioSession = true
    } catch {
      if reportFailure { notice = "画中画音频会话暂不可用，请稍后重试。" }
      return false
    }
    notice = nil
    playback.setPaused(false)
    isPaused = false
    isPreparedForAutomaticStart = true
    userClose = true
    restoringInline = false
    controller?.canStartPictureInPictureAutomaticallyFromInline = true
    controller?.invalidatePlaybackState()
    startTicker()
    render()
    return true
  }

  func start() {
    guard !isActive, !isStarting else { return }
    guard prepareForAutomaticStart(reportFailure: true) else { return }
    isStarting = true
    startIssued = false
    startWhenReady()
    startDeadline?.cancel()
    startDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, self.isStarting else { return }
      self.stop()
      self.notice = "画中画未能开启，请保持 App 在前台后重试，或检查系统的画中画设置。"
    }
  }

  func stop() {
    isPreparedForAutomaticStart = false
    controller?.canStartPictureInPictureAutomaticallyFromInline = false
    userClose = false
    startDeadline?.cancel()
    startDeadline = nil
    isStarting = false
    ticker?.invalidate()
    ticker = nil
    snapshot = FloatingPiPSnapshot()
    render()
    controller?.stopPictureInPicture()
    deactivateAudio()
    if controller?.isPictureInPictureActive != true { isActive = false }
  }

  private func startWhenReady() {
    guard isStarting, !startIssued, sourceView?.window != nil,
      controller?.isPictureInPicturePossible == true else { return }
    startIssued = true
    controller?.startPictureInPicture()
  }

  private func startTicker() {
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.render(); self?.startWhenReady() }
    }
  }

  private func render() {
    // Clear the external frame even after SwiftUI has detached its source view.
    guard let layer = sourceView?.displayLayer ?? controller?.contentSource?.sampleBufferDisplayLayer else { return }
    let content = snapshot.presentation(at: Date(), cyclingSince: isActive ? startedAt : nil, paused: isPaused)
    guard let sample = FloatingPiPFrameRenderer.sample(content) else { return }
    if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
    if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
  }

  private func deactivateAudio() {
    guard ownsAudioSession else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    ownsAudioSession = false
  }

  // AVKit may query playback state off the main thread; UI changes are dispatched explicitly.
  nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor [weak self] in
      guard let self, self.userClose else { return }
      self.isStarting = true
      self.startIssued = true
      self.startTicker()
    }
  }

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.userClose else { pictureInPictureController.stopPictureInPicture(); return }
      self.startDeadline?.cancel()
      self.startDeadline = nil
      self.startedAt = Date()
      self.isActive = true
      self.isStarting = false
      self.render()
    }
  }

  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    Task { @MainActor [weak self] in
      self?.stop()
      self?.notice = "系统暂时无法开启画中画，请返回 App 重试。"
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let close = self.userClose && !self.restoringInline
      let resumeAutomatic = self.isPreparedForAutomaticStart && !close
      self.isPreparedForAutomaticStart = false
      self.isActive = false
      self.isStarting = false
      self.isPaused = false
      self.playback.setPaused(false)
      self.ticker?.invalidate()
      self.ticker = nil
      self.deactivateAudio()
      if close { self.onSystemClose?() }
      else if resumeAutomatic { self.prepareForAutomaticStart() }
    }
  }

  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    Task { @MainActor [weak self] in
      self?.restoringInline = true
      completionHandler(self != nil)
    }
  }

  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    playback.setPaused(!playing)
    Task { @MainActor [weak self] in
      self?.isPaused = !playing
      pictureInPictureController.invalidatePlaybackState()
      self?.render()
    }
  }
  nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }
  nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { playback.isPaused }
  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void) { completionHandler() }
  nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
}

private final class FloatingPiPPlaybackState: @unchecked Sendable {
  private let lock = NSLock()
  private var paused = false
  var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
  func setPaused(_ value: Bool) { lock.lock(); defer { lock.unlock() }; paused = value }
}

final class FloatingPiPSourceView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  var onWindowChange: (() -> Void)?
  override func didMoveToWindow() { super.didMoveToWindow(); onWindowChange?() }
}

struct FloatingPiPSource: UIViewRepresentable {
  let controller: FloatingPositionsPiP
  func makeUIView(context: Context) -> FloatingPiPSourceView {
    let view = FloatingPiPSourceView()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = true
    view.accessibilityLabel = "跨 App 持仓浮窗"
    view.accessibilityIdentifier = "floating.positions.pipStatus"
    view.displayLayer.videoGravity = .resizeAspect
    controller.attach(view)
    return view
  }
  func updateUIView(_ uiView: FloatingPiPSourceView, context: Context) {
    uiView.accessibilityValue = controller.isActive ? "画中画已开启" : controller.isStarting ? "正在开启画中画" : "App 内显示"
  }
}

enum FloatingPiPFrameRenderer {
  static func sample(_ content: FloatingPiPPresentation) -> CMSampleBuffer? {
    let width = 640, height = 320
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    UIGraphicsPushContext(context)
    defer { UIGraphicsPopContext() }
    UIColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1).setFill()
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let muted = UIColor(white: 0.66, alpha: 1)
    let profitColor = content.loss ? UIColor(red: 0.96, green: 0.27, blue: 0.36, alpha: 1)
      : UIColor(red: 0.05, green: 0.8, blue: 0.5, alpha: 1)
    text(content.title + " " + content.side, in: CGRect(x: 26, y: 36, width: 484, height: 46), size: 38, color: .white, bold: true)
    text(content.page, in: CGRect(x: 538, y: 43, width: 80, height: 34), size: 26, color: muted)
    text("市价", in: CGRect(x: 26, y: 112, width: 280, height: 32), size: 25, color: muted)
    text("浮盈", in: CGRect(x: 346, y: 112, width: 270, height: 32), size: 25, color: muted)
    text(content.price, in: CGRect(x: 26, y: 158, width: 292, height: 55), size: 42, color: .white, bold: true)
    text(content.profit, in: CGRect(x: 346, y: 158, width: 270, height: 55), size: 42, color: profitColor, bold: true)
    text(content.footer, in: CGRect(x: 26, y: 258, width: 590, height: 32), size: 24, color: muted)
    var description: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
      formatDescriptionOut: &description) == noErr, let description else { return nil }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
      formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }

  private static func text(_ value: String, in rect: CGRect, size: CGFloat, color: UIColor, bold: Bool = false) {
    let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    let measured = (value as NSString).size(withAttributes: [.font: font]).width
    let fitted = UIFont.monospacedDigitSystemFont(ofSize: max(16, size * min(1, rect.width / max(1, measured))),
      weight: bold ? .semibold : .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (value as NSString).draw(in: rect, withAttributes: [.font: fitted, .foregroundColor: color, .paragraphStyle: paragraph])
  }
}
