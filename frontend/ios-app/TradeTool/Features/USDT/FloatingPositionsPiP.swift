import AVKit
import SwiftUI

struct FloatingPiPSnapshot: Equatable {
  static let pageSize = FloatingPiPFrameLayout.maximumRows
  var positions: [FloatingPosition] = []
  var updatedAt: Date?
  var status = "正在同步…"

  func presentation(at now: Date, cyclingSince: Date?, paused: Bool) -> FloatingPiPPresentation {
    let pageCount = max(1, (positions.count + Self.pageSize - 1) / Self.pageSize)
    let offset = cyclingSince.map { max(0, Int(now.timeIntervalSince($0) / 5)) } ?? 0
    let pageIndex = offset % pageCount
    let visible = positions.dropFirst(pageIndex * Self.pageSize).prefix(Self.pageSize)
    let rows = visible.map { position in
      // Fresh quotes for other rows or a successful REST read cannot renew this row's old quote.
      let valuationTime = updatedAt.flatMap { rowTime in position.quoteTime.map { min(rowTime, $0) } }
      let stale = valuationTime.map { now.timeIntervalSince($0) > 12 } ?? true
      return FloatingPiPRow(id: position.id, symbol: position.symbol, side: position.isShort ? "空" : "多",
        price: !paused && !stale ? position.priceText : "--",
        profit: !paused && !stale ? position.profitText : "--",
        loss: position.profit.map { $0 < 0 } ?? false, stale: stale, updatedAt: valuationTime)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let timestamp = rows.compactMap(\.updatedAt).min().map { formatter.string(from: $0) }
    let footer: String
    if paused { footer = "已暂停 · 点击播放恢复" }
    else if rows.contains(where: \.stale) {
      footer = (rows.allSatisfy(\.stale) ? "更新延迟" : "部分行情延迟") + " · " + (timestamp ?? "--")
    } else { footer = timestamp.map { "更新 " + $0 } ?? status }
    return FloatingPiPPresentation(title: "持仓", rows: rows, totalCount: positions.count,
      page: pageCount > 1 ? "\(pageIndex + 1)/\(pageCount)" : "", footer: footer)
  }
}

struct FloatingPiPRow: Equatable {
  let id: String
  let symbol: String
  let side: String
  let price: String
  let profit: String
  let loss: Bool
  let stale: Bool
  let updatedAt: Date?
}

struct FloatingPiPPresentation: Equatable {
  let title: String
  let rows: [FloatingPiPRow]
  let totalCount: Int
  let page: String
  let footer: String
}

/// One geometry drives both the video format and the covered AVKit source.
struct FloatingPiPFrameLayout {
  static let maximumRows = 3
  static let videoWidth = 640
  static let firstRowTop = 80
  static let rowStride = 82
  let rowCount: Int

  init(rowCount: Int) { self.rowCount = min(Self.maximumRows, max(0, rowCount)) }

  // Empty/loading snapshots retain one compact status area, never a zero-size source.
  var videoHeight: Int { 158 + max(1, rowCount) * Self.rowStride }
  var sourceSize: CGSize { CGSize(width: 160, height: Double(videoHeight) / 4) }
  var footerTop: CGFloat { CGFloat(videoHeight - 42) }
  var emptyStatusTop: CGFloat { CGFloat(Self.firstRowTop) + CGFloat(videoHeight - Self.firstRowTop - 54) / 2 }
}

/// Retains only the newest presentation while AVKit applies backpressure.
@MainActor
final class FloatingPiPFrameDelivery<Frame> {
  private var pending: Frame?
  private var requesting = false
  private let isReady: () -> Bool
  private let request: (@escaping @MainActor () -> Void) -> Void
  private let stop: () -> Void
  private let enqueue: (Frame) -> Void

  init(isReady: @escaping () -> Bool,
    request: @escaping (@escaping @MainActor () -> Void) -> Void,
    stop: @escaping () -> Void, enqueue: @escaping (Frame) -> Void) {
    self.isReady = isReady
    self.request = request
    self.stop = stop
    self.enqueue = enqueue
  }

  func submit(_ frame: Frame) {
    pending = frame
    deliver()
  }

  func cancel() {
    pending = nil
    if requesting { stop(); requesting = false }
  }

  private func deliver() {
    guard let frame = pending else { return }
    guard isReady() else {
      if !requesting {
        requesting = true
        request { [weak self] in self?.deliver() }
      }
      return
    }
    pending = nil
    if requesting { stop(); requesting = false }
    enqueue(frame)
  }
}

enum FloatingPiPRenderSchedule {
  @MainActor
  static func timer(interval: TimeInterval = 1, tick: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { tick() }
    }
    // UI tracking must not pause carousel/staleness updates or a pending automatic PiP start.
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }
}

/// The system owns the external window; no private overlay or silent audio is used.
@MainActor
final class FloatingPositionsPiP: NSObject, ObservableObject,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  @Published private var lifecycle = FloatingPiPLifecycle()
  var isActive: Bool { lifecycle.isActive }
  var isStarting: Bool { lifecycle.isStarting }
  @Published private(set) var isPaused = false
  @Published private(set) var sourceSize = FloatingPanelPlacement.sourceSize(forRowCount: 0)
  @Published var notice: String?
  var onSystemClose: (() -> Void)?
  var keepsUpdating: Bool { (isActive || isStarting) && !isPaused }
  private nonisolated let playback = FloatingPiPPlaybackState()
  private var controller: AVPictureInPictureController?
  private weak var sourceView: FloatingPiPSourceView?
  private var possibility: NSKeyValueObservation?
  private var ticker: Timer?
  private var frameDelivery: FloatingPiPFrameDelivery<FloatingPiPPresentation>?
  private var startDeadline: Task<Void, Never>?
  private var ownsAudioSession = false
  private var startedAt: Date?
  private var snapshot = FloatingPiPSnapshot()

  func attach(_ view: FloatingPiPSourceView) {
    sourceView = view
    frameDelivery?.cancel()
    let layer = view.displayLayer
    frameDelivery = FloatingPiPFrameDelivery(
      isReady: {
        if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
        return layer.isReadyForMoreMediaData
      },
      request: { ready in
        layer.requestMediaDataWhenReady(on: .main) { MainActor.assumeIsolated { ready() } }
      }, stop: { layer.stopRequestingMediaData() },
      enqueue: { [weak self] content in
        if let sample = FloatingPiPFrameRenderer.sample(content) {
          layer.enqueue(sample)
          let size = FloatingPanelPlacement.sourceSize(forRowCount: content.rows.count)
          if self?.sourceSize != size { self?.sourceSize = size }
        }
      })
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
    pip.canStartPictureInPictureAutomaticallyFromInline = false
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

  private func preparePlayback() -> Bool {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--fixture-pip-unavailable") {
        notice = "此设备暂不支持画中画。"
        return false
      }
    #endif
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      notice = "此设备暂不支持画中画。"
      return false
    }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try audio.setActive(true)
      ownsAudioSession = true
    } catch {
      notice = "画中画音频会话暂不可用，请稍后重试。"
      return false
    }
    notice = nil
    playback.setPaused(false)
    isPaused = false
    controller?.invalidatePlaybackState()
    startTicker()
    render()
    return true
  }

  func start() {
    guard lifecycle.request() else { return }
    guard preparePlayback() else { lifecycle.stop(); return }
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
    lifecycle.stop(awaitingSystemStop: controller?.isPictureInPictureActive == true)
    startDeadline?.cancel()
    startDeadline = nil
    ticker?.invalidate()
    ticker = nil
    snapshot = FloatingPiPSnapshot()
    render()
    controller?.stopPictureInPicture()
    deactivateAudio()
  }

  private func startWhenReady() {
    guard lifecycle.issueStart(sourceReady: sourceView?.window != nil
      && controller?.isPictureInPicturePossible == true) else { return }
    controller?.startPictureInPicture()
  }

  private func startTicker() {
    ticker?.invalidate()
    ticker = FloatingPiPRenderSchedule.timer { [weak self] in
      self?.render(); self?.startWhenReady()
    }
  }

  private func render() {
    // The covered source remains attached, including while the external window closes.
    let content = snapshot.presentation(at: Date(), cyclingSince: isActive ? startedAt : nil, paused: isPaused)
    frameDelivery?.submit(content)
  }

  private func deactivateAudio() {
    guard ownsAudioSession else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    ownsAudioSession = false
  }

  // AVKit may query playback state off the main thread; UI changes are dispatched explicitly.
  nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor [weak self] in
      guard let self, self.isStarting else { return }
      self.startTicker()
    }
  }

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.lifecycle.didStart() else { pictureInPictureController.stopPictureInPicture(); return }
      self.startDeadline?.cancel()
      self.startDeadline = nil
      self.startedAt = Date()
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
      let requested = self.lifecycle.didStop()
      self.isPaused = false
      self.playback.setPaused(false)
      if self.isStarting {
        pictureInPictureController.invalidatePlaybackState()
        self.startWhenReady()
        return
      }
      self.startDeadline?.cancel()
      self.startDeadline = nil
      self.ticker?.invalidate()
      self.ticker = nil
      self.deactivateAudio()
      if requested { self.onSystemClose?() }
    }
  }

  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    Task { @MainActor [weak self] in
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
    view.isAccessibilityElement = false
    view.accessibilityElementsHidden = true
    view.displayLayer.videoGravity = .resizeAspect
    controller.attach(view)
    return view
  }
  func updateUIView(_ uiView: FloatingPiPSourceView, context: Context) {
    // The source stays covered in the app; the system PiP is the only visible presentation.
  }
}

enum FloatingPiPFrameRenderer {
  static func sample(_ content: FloatingPiPPresentation) -> CMSampleBuffer? {
    let layout = FloatingPiPFrameLayout(rowCount: content.rows.count)
    let width = FloatingPiPFrameLayout.videoWidth, height = layout.videoHeight
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
    text(content.title + " · \(content.totalCount) 笔", in: CGRect(x: 24, y: 22, width: 470, height: 40),
      size: 30, color: .white, bold: true)
    text(content.page, in: CGRect(x: 524, y: 25, width: 92, height: 35), size: 26, color: muted)
    if content.rows.isEmpty {
      text(content.footer, in: CGRect(x: 24, y: layout.emptyStatusTop, width: 592, height: 54), size: 34, color: muted)
    }
    for (index, row) in content.rows.prefix(FloatingPiPFrameLayout.maximumRows).enumerated() {
      let y = CGFloat(FloatingPiPFrameLayout.firstRowTop + index * FloatingPiPFrameLayout.rowStride)
      let color = row.stale ? muted : row.loss ? UIColor(red: 0.96, green: 0.27, blue: 0.36, alpha: 1)
        : UIColor(red: 0.05, green: 0.8, blue: 0.5, alpha: 1)
      text(row.symbol + " " + row.side, in: CGRect(x: 24, y: y, width: 336, height: 39),
        size: 31, color: .white, bold: true)
      text(row.profit, in: CGRect(x: 368, y: y, width: 248, height: 39), size: 32, color: color, bold: true)
      text("市价 " + row.price, in: CGRect(x: 24, y: y + 39, width: 592, height: 29), size: 23, color: muted)
    }
    if !content.rows.isEmpty {
      text(content.footer, in: CGRect(x: 24, y: layout.footerTop, width: 592, height: 29), size: 22, color: muted)
    }
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
