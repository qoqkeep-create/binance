import Foundation

struct ChartAnchor: Codable, Equatable, Hashable, Sendable {
  let openTime: Int64
  let price: Decimal

  init?(openTime: Int64, price: Decimal) {
    guard openTime >= 0,
      NSDecimalNumber(decimal: price).doubleValue.isFinite
    else {
      return nil
    }
    self.openTime = openTime
    self.price = price
  }

  var doublePrice: Double {
    NSDecimalNumber(decimal: price).doubleValue
  }
}

enum ChartAnnotationColorToken: String, Codable, Sendable {
  case neutral
  case positive
  case negative
  case yellow
  case magenta
  case violet

  var chartColor: ChartColor {
    switch self {
    case .neutral: .neutral
    case .positive: .positive
    case .negative: .negative
    case .yellow: .ema21
    case .magenta: .ema55
    case .violet: .ema144
    }
  }
}

struct ChartAnnotationStyle: Codable, Equatable, Sendable {
  static let standard = ChartAnnotationStyle(
    color: .yellow,
    lineWidth: 1,
    dashLength: 0,
    gapLength: 0
  )!

  let color: ChartAnnotationColorToken
  let lineWidth: Float
  let dashLength: Float
  let gapLength: Float

  init?(
    color: ChartAnnotationColorToken,
    lineWidth: Float,
    dashLength: Float,
    gapLength: Float
  ) {
    guard lineWidth.isFinite,
      lineWidth > 0,
      lineWidth <= 12,
      dashLength.isFinite,
      dashLength >= 0,
      gapLength.isFinite,
      gapLength >= 0
    else {
      return nil
    }
    self.color = color
    self.lineWidth = lineWidth
    self.dashLength = dashLength
    self.gapLength = gapLength
  }

  var isValid: Bool {
    lineWidth.isFinite && lineWidth > 0 && lineWidth <= 12
      && dashLength.isFinite && dashLength >= 0
      && gapLength.isFinite && gapLength >= 0
  }
}

struct ChartAnnotation: Codable, Equatable, Identifiable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let id: UUID
  let toolID: String
  let anchors: [ChartAnchor]
  let style: ChartAnnotationStyle
  let groupID: UUID?
  let isLocked: Bool
  let isHidden: Bool
  let createdAt: Date
  let updatedAt: Date

  init?(
    id: UUID = UUID(),
    toolID: String,
    anchors: [ChartAnchor],
    style: ChartAnnotationStyle = .standard,
    groupID: UUID? = nil,
    isLocked: Bool = false,
    isHidden: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    guard !toolID.isEmpty,
      !anchors.isEmpty,
      style.isValid
    else {
      return nil
    }
    schemaVersion = Self.schemaVersion
    self.id = id
    self.toolID = toolID
    self.anchors = anchors
    self.style = style
    self.groupID = groupID
    self.isLocked = isLocked
    self.isHidden = isHidden
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  func replacing(
    anchors: [ChartAnchor]? = nil,
    style: ChartAnnotationStyle? = nil,
    groupID: UUID?? = nil,
    isLocked: Bool? = nil,
    isHidden: Bool? = nil,
    updatedAt: Date = Date()
  ) -> ChartAnnotation? {
    ChartAnnotation(
      id: id,
      toolID: toolID,
      anchors: anchors ?? self.anchors,
      style: style ?? self.style,
      groupID: groupID ?? self.groupID,
      isLocked: isLocked ?? self.isLocked,
      isHidden: isHidden ?? self.isHidden,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

enum ChartDrawingGeometryKind: String, Sendable {
  case horizontalLine
  case verticalLine
  case segment
  case ray
  case rangeMeasure
}

struct ChartDrawingToolDescriptor: Equatable, Sendable {
  let id: String
  let minimumAnchorCount: Int
  let maximumAnchorCount: Int
  let geometryKind: ChartDrawingGeometryKind

  init?(
    id: String,
    minimumAnchorCount: Int,
    maximumAnchorCount: Int,
    geometryKind: ChartDrawingGeometryKind
  ) {
    guard !id.isEmpty,
      minimumAnchorCount > 0,
      maximumAnchorCount >= minimumAnchorCount,
      maximumAnchorCount <= 16
    else {
      return nil
    }
    self.id = id
    self.minimumAnchorCount = minimumAnchorCount
    self.maximumAnchorCount = maximumAnchorCount
    self.geometryKind = geometryKind
  }

  func accepts(anchorCount: Int) -> Bool {
    minimumAnchorCount...maximumAnchorCount ~= anchorCount
  }
}

protocol ChartDrawingToolPlugin: Sendable {
  var descriptor: ChartDrawingToolDescriptor { get }
}

private struct BuiltInChartDrawingTool: ChartDrawingToolPlugin {
  let descriptor: ChartDrawingToolDescriptor
}

struct ChartDrawingToolRegistry: Sendable {
  private let plugins: [String: any ChartDrawingToolPlugin]

  init?(_ plugins: [any ChartDrawingToolPlugin]) {
    let pairs = plugins.map { ($0.descriptor.id, $0) }
    guard !pairs.isEmpty,
      Set(pairs.map(\.0)).count == pairs.count
    else {
      return nil
    }
    self.plugins = Dictionary(uniqueKeysWithValues: pairs)
  }

  var descriptors: [ChartDrawingToolDescriptor] {
    plugins.values.map(\.descriptor).sorted { $0.id < $1.id }
  }

  func descriptor(id: String) -> ChartDrawingToolDescriptor? {
    plugins[id]?.descriptor
  }

  func validates(_ annotation: ChartAnnotation) -> Bool {
    annotation.schemaVersion == ChartAnnotation.schemaVersion
      && annotation.style.isValid
      && annotation.anchors.allSatisfy {
        $0.openTime >= 0 && $0.doublePrice.isFinite
      }
      && descriptor(id: annotation.toolID)?
        .accepts(anchorCount: annotation.anchors.count) == true
  }

  static let standard: ChartDrawingToolRegistry = {
    let definitions: [(
      String, Int, ChartDrawingGeometryKind
    )] = [
      ("horizontal-line", 1, .horizontalLine),
      ("vertical-line", 1, .verticalLine),
      ("trend-line", 2, .segment),
      ("ray", 2, .ray),
      ("range-measure", 2, .rangeMeasure),
    ]
    let plugins: [any ChartDrawingToolPlugin] = definitions.compactMap {
      guard let descriptor = ChartDrawingToolDescriptor(
        id: $0.0,
        minimumAnchorCount: $0.1,
        maximumAnchorCount: $0.1,
        geometryKind: $0.2
      ) else {
        return nil
      }
      return BuiltInChartDrawingTool(descriptor: descriptor)
    }
    return ChartDrawingToolRegistry(plugins)!
  }()
}

struct ChartDrawingPoint: Equatable, Sendable {
  let x: Float
  let y: Float

  var isValid: Bool { x.isFinite && y.isFinite }
}

struct ChartDrawingProjection: Sendable {
  let coordinateSpace: RelativeChartCoordinateSpace
  let plot: ChartPanelRect

  func point(for anchor: ChartAnchor) -> ChartDrawingPoint? {
    guard let x = coordinateSpace.screenX(openTime: anchor.openTime),
      let y = coordinateSpace.screenY(price: anchor.doublePrice)
    else {
      return nil
    }
    let point = ChartDrawingPoint(x: x, y: y)
    return point.isValid ? point : nil
  }
}

struct ChartDrawingHit: Equatable, Sendable {
  let annotationID: UUID
  let anchorIndex: Int?
  let distancePoints: Float
}

enum ChartDrawingHitTester {
  static func nearest(
    point: ChartDrawingPoint,
    annotations: [ChartAnnotation],
    registry: ChartDrawingToolRegistry = .standard,
    projection: ChartDrawingProjection,
    tolerancePoints: Float = 12
  ) -> ChartDrawingHit? {
    guard point.isValid,
      tolerancePoints.isFinite,
      tolerancePoints > 0
    else {
      return nil
    }
    var best: ChartDrawingHit?
    for annotation in annotations.reversed()
    where !annotation.isHidden && registry.validates(annotation) {
      guard let descriptor = registry.descriptor(
        id: annotation.toolID
      ) else {
        continue
      }
      let points = annotation.anchors.compactMap(projection.point)
      guard points.count == annotation.anchors.count else {
        continue
      }
      for (index, anchorPoint) in points.enumerated() {
        let distance = hypotf(
          point.x - anchorPoint.x,
          point.y - anchorPoint.y
        )
        best = choose(
          best,
          candidate: ChartDrawingHit(
            annotationID: annotation.id,
            anchorIndex: index,
            distancePoints: distance
          ),
          tolerance: tolerancePoints
        )
      }
      let geometryDistance = distance(
        from: point,
        to: points,
        kind: descriptor.geometryKind,
        plot: projection.plot
      )
      best = choose(
        best,
        candidate: ChartDrawingHit(
          annotationID: annotation.id,
          anchorIndex: nil,
          distancePoints: geometryDistance
        ),
        tolerance: tolerancePoints
      )
    }
    return best
  }

  private static func choose(
    _ current: ChartDrawingHit?,
    candidate: ChartDrawingHit,
    tolerance: Float
  ) -> ChartDrawingHit? {
    guard candidate.distancePoints.isFinite,
      candidate.distancePoints <= tolerance
    else {
      return current
    }
    guard let current else { return candidate }
    if candidate.distancePoints < current.distancePoints {
      return candidate
    }
    if candidate.distancePoints == current.distancePoints,
      candidate.anchorIndex != nil,
      current.anchorIndex == nil {
      return candidate
    }
    return current
  }

  private static func distance(
    from point: ChartDrawingPoint,
    to anchors: [ChartDrawingPoint],
    kind: ChartDrawingGeometryKind,
    plot: ChartPanelRect
  ) -> Float {
    guard let first = anchors.first else { return .infinity }
    switch kind {
    case .horizontalLine:
      guard point.x >= plot.left, point.x <= plot.right else {
        return .infinity
      }
      return abs(point.y - first.y)
    case .verticalLine:
      guard point.y >= plot.top, point.y <= plot.bottom else {
        return .infinity
      }
      return abs(point.x - first.x)
    case .segment:
      guard anchors.count == 2 else { return .infinity }
      return lineDistance(
        point,
        start: anchors[0],
        end: anchors[1],
        isRay: false
      )
    case .ray:
      guard anchors.count == 2 else { return .infinity }
      return lineDistance(
        point,
        start: anchors[0],
        end: anchors[1],
        isRay: true
      )
    case .rangeMeasure:
      guard anchors.count == 2 else { return .infinity }
      let second = anchors[1]
      let left = min(first.x, second.x)
      let right = max(first.x, second.x)
      let top = min(first.y, second.y)
      let bottom = max(first.y, second.y)
      return min(
        lineDistance(
          point,
          start: ChartDrawingPoint(x: left, y: top),
          end: ChartDrawingPoint(x: right, y: top),
          isRay: false
        ),
        lineDistance(
          point,
          start: ChartDrawingPoint(x: right, y: top),
          end: ChartDrawingPoint(x: right, y: bottom),
          isRay: false
        ),
        lineDistance(
          point,
          start: ChartDrawingPoint(x: right, y: bottom),
          end: ChartDrawingPoint(x: left, y: bottom),
          isRay: false
        ),
        lineDistance(
          point,
          start: ChartDrawingPoint(x: left, y: bottom),
          end: ChartDrawingPoint(x: left, y: top),
          isRay: false
        )
      )
    }
  }

  private static func lineDistance(
    _ point: ChartDrawingPoint,
    start: ChartDrawingPoint,
    end: ChartDrawingPoint,
    isRay: Bool
  ) -> Float {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared.isFinite, lengthSquared > 0 else {
      return hypotf(point.x - start.x, point.y - start.y)
    }
    let projection = (
      (point.x - start.x) * dx + (point.y - start.y) * dy
    ) / lengthSquared
    let bounded = isRay
      ? max(0, projection)
      : min(1, max(0, projection))
    return hypotf(
      point.x - (start.x + bounded * dx),
      point.y - (start.y + bounded * dy)
    )
  }
}

enum ChartDrawingSceneCompiler {
  static func lineSegments(
    annotations: [ChartAnnotation],
    registry: ChartDrawingToolRegistry = .standard,
    projection: ChartDrawingProjection
  ) -> [ChartLineSegmentInstance] {
    annotations.flatMap { annotation -> [ChartLineSegmentInstance] in
      guard !annotation.isHidden,
        registry.validates(annotation),
        let descriptor = registry.descriptor(id: annotation.toolID)
      else {
        return []
      }
      let points = annotation.anchors.compactMap(projection.point)
      guard points.count == annotation.anchors.count else { return [] }
      return primitiveSegments(
        points: points,
        kind: descriptor.geometryKind,
        plot: projection.plot
      ).map {
        ChartLineSegmentInstance(
          start: ChartPolylinePoint(x: $0.0.x, y: $0.0.y),
          end: ChartPolylinePoint(x: $0.1.x, y: $0.1.y),
          width: annotation.style.lineWidth,
          dashLength: annotation.style.dashLength,
          gapLength: annotation.style.gapLength,
          dashPhase: 0,
          color: annotation.style.color.chartColor,
          antialias: true
        )
      }
    }.filter(\.isValid)
  }

  private static func primitiveSegments(
    points: [ChartDrawingPoint],
    kind: ChartDrawingGeometryKind,
    plot: ChartPanelRect
  ) -> [(ChartDrawingPoint, ChartDrawingPoint)] {
    guard let first = points.first else { return [] }
    switch kind {
    case .horizontalLine:
      return [(
        ChartDrawingPoint(x: plot.left, y: first.y),
        ChartDrawingPoint(x: plot.right, y: first.y)
      )]
    case .verticalLine:
      return [(
        ChartDrawingPoint(x: first.x, y: plot.top),
        ChartDrawingPoint(x: first.x, y: plot.bottom)
      )]
    case .segment:
      return points.count == 2 ? [(points[0], points[1])] : []
    case .ray:
      guard points.count == 2 else { return [] }
      let dx = points[1].x - points[0].x
      let dy = points[1].y - points[0].y
      let scale = max(plot.width, plot.height) * 4
      let length = hypotf(dx, dy)
      guard length > 0 else { return [] }
      return [(
        points[0],
        ChartDrawingPoint(
          x: points[0].x + dx / length * scale,
          y: points[0].y + dy / length * scale
        )
      )]
    case .rangeMeasure:
      guard points.count == 2 else { return [] }
      let left = min(points[0].x, points[1].x)
      let right = max(points[0].x, points[1].x)
      let top = min(points[0].y, points[1].y)
      let bottom = max(points[0].y, points[1].y)
      let topLeft = ChartDrawingPoint(x: left, y: top)
      let topRight = ChartDrawingPoint(x: right, y: top)
      let bottomRight = ChartDrawingPoint(x: right, y: bottom)
      let bottomLeft = ChartDrawingPoint(x: left, y: bottom)
      return [
        (topLeft, topRight),
        (topRight, bottomRight),
        (bottomRight, bottomLeft),
        (bottomLeft, topLeft),
      ]
    }
  }
}

struct ChartAnnotationDocument: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let stream: ChartStreamKeyPayload
  private(set) var annotations: [ChartAnnotation]

  init(stream: ChartStreamKey, annotations: [ChartAnnotation] = []) {
    schemaVersion = Self.schemaVersion
    self.stream = ChartStreamKeyPayload(stream)
    self.annotations = annotations
  }

  var streamKey: ChartStreamKey {
    ChartStreamKey(symbol: stream.symbol, interval: stream.interval)
  }

  func isValid(registry: ChartDrawingToolRegistry = .standard) -> Bool {
    schemaVersion == Self.schemaVersion
      && !stream.symbol.isEmpty
      && !stream.interval.isEmpty
      && Set(annotations.map(\.id)).count == annotations.count
      && annotations.allSatisfy(registry.validates)
  }

  fileprivate func replacing(
    annotations: [ChartAnnotation]
  ) -> ChartAnnotationDocument {
    ChartAnnotationDocument(stream: streamKey, annotations: annotations)
  }
}

struct ChartStreamKeyPayload: Codable, Equatable, Sendable {
  let symbol: String
  let interval: String

  init(_ stream: ChartStreamKey) {
    symbol = stream.symbol
    interval = stream.interval
  }
}

struct ChartAnnotationEditor: Sendable {
  private(set) var document: ChartAnnotationDocument
  private(set) var selectedAnnotationID: UUID?
  private var undoStack: [[ChartAnnotation]] = []
  private var redoStack: [[ChartAnnotation]] = []
  private let historyLimit: Int
  private let registry: ChartDrawingToolRegistry

  init(
    document: ChartAnnotationDocument,
    registry: ChartDrawingToolRegistry = .standard,
    historyLimit: Int = 100
  ) {
    self.document = document.isValid(registry: registry)
      ? document
      : ChartAnnotationDocument(stream: document.streamKey)
    self.registry = registry
    self.historyLimit = max(1, min(1_000, historyLimit))
  }

  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }

  mutating func select(_ id: UUID?) {
    selectedAnnotationID = document.annotations.contains { $0.id == id }
      ? id
      : nil
  }

  mutating func create(_ annotation: ChartAnnotation) -> Bool {
    guard registry.validates(annotation),
      !document.annotations.contains(where: { $0.id == annotation.id })
    else {
      return false
    }
    return commit(document.annotations + [annotation])
  }

  mutating func update(_ annotation: ChartAnnotation) -> Bool {
    guard registry.validates(annotation),
      let index = document.annotations.firstIndex(
        where: { $0.id == annotation.id }
      ),
      !document.annotations[index].isLocked
    else {
      return false
    }
    var next = document.annotations
    next[index] = annotation
    return commit(next)
  }

  mutating func remove(id: UUID) -> Bool {
    guard let index = document.annotations.firstIndex(
      where: { $0.id == id }
    ), !document.annotations[index].isLocked else {
      return false
    }
    var next = document.annotations
    next.remove(at: index)
    if selectedAnnotationID == id { selectedAnnotationID = nil }
    return commit(next)
  }

  mutating func setLocked(_ locked: Bool, id: UUID) -> Bool {
    replaceFlags(id: id, isLocked: locked, isHidden: nil)
  }

  mutating func setHidden(_ hidden: Bool, id: UUID) -> Bool {
    replaceFlags(id: id, isLocked: nil, isHidden: hidden)
  }

  mutating func moveAnchor(
    annotationID: UUID,
    anchorIndex: Int,
    to anchor: ChartAnchor
  ) -> Bool {
    guard let annotation = document.annotations.first(
      where: { $0.id == annotationID }
    ), !annotation.isLocked,
      annotation.anchors.indices.contains(anchorIndex)
    else {
      return false
    }
    var anchors = annotation.anchors
    anchors[anchorIndex] = anchor
    guard let changed = annotation.replacing(anchors: anchors) else {
      return false
    }
    return update(changed)
  }

  mutating func undo() -> Bool {
    guard let previous = undoStack.popLast() else { return false }
    redoStack.append(document.annotations)
    trim(&redoStack)
    document = document.replacing(annotations: previous)
    if let selectedAnnotationID,
      !previous.contains(where: { $0.id == selectedAnnotationID }) {
      self.selectedAnnotationID = nil
    }
    return true
  }

  mutating func redo() -> Bool {
    guard let next = redoStack.popLast() else { return false }
    undoStack.append(document.annotations)
    trim(&undoStack)
    document = document.replacing(annotations: next)
    return true
  }

  private mutating func replaceFlags(
    id: UUID,
    isLocked: Bool?,
    isHidden: Bool?
  ) -> Bool {
    guard let index = document.annotations.firstIndex(
      where: { $0.id == id }
    ), let changed = document.annotations[index].replacing(
      isLocked: isLocked,
      isHidden: isHidden
    ) else {
      return false
    }
    var next = document.annotations
    next[index] = changed
    return commit(next)
  }

  private mutating func commit(_ annotations: [ChartAnnotation]) -> Bool {
    guard annotations != document.annotations else { return false }
    let next = document.replacing(annotations: annotations)
    guard next.isValid(registry: registry) else { return false }
    undoStack.append(document.annotations)
    trim(&undoStack)
    redoStack.removeAll(keepingCapacity: true)
    document = next
    return true
  }

  private func trim(_ stack: inout [[ChartAnnotation]]) {
    if stack.count > historyLimit {
      stack.removeFirst(stack.count - historyLimit)
    }
  }
}

struct ChartDrawingDraft: Equatable, Sendable {
  private(set) var toolID: String?
  private(set) var anchors: [ChartAnchor] = []

  mutating func begin(
    toolID: String,
    registry: ChartDrawingToolRegistry = .standard
  ) -> Bool {
    guard registry.descriptor(id: toolID) != nil else { return false }
    self.toolID = toolID
    anchors.removeAll(keepingCapacity: true)
    return true
  }

  mutating func append(
    _ anchor: ChartAnchor,
    registry: ChartDrawingToolRegistry = .standard
  ) -> ChartAnnotation? {
    guard let toolID,
      let descriptor = registry.descriptor(id: toolID),
      anchors.count < descriptor.maximumAnchorCount
    else {
      return nil
    }
    anchors.append(anchor)
    guard descriptor.accepts(anchorCount: anchors.count) else {
      return nil
    }
    let annotation = ChartAnnotation(toolID: toolID, anchors: anchors)
    cancel()
    return annotation
  }

  mutating func cancel() {
    toolID = nil
    anchors.removeAll(keepingCapacity: true)
  }
}

enum ChartAnnotationStoreError: Error, Equatable {
  case invalidDocument
  case wrongStream
}

struct ChartAnnotationJSONStore: Sendable {
  let directoryURL: URL

  func save(
    _ document: ChartAnnotationDocument,
    registry: ChartDrawingToolRegistry = .standard
  ) throws {
    guard document.isValid(registry: registry) else {
      throw ChartAnnotationStoreError.invalidDocument
    }
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    try data.write(to: fileURL(for: document.streamKey), options: .atomic)
  }

  func load(
    stream: ChartStreamKey,
    registry: ChartDrawingToolRegistry = .standard
  ) throws -> ChartAnnotationDocument? {
    let url = fileURL(for: stream)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let document = try JSONDecoder().decode(
      ChartAnnotationDocument.self,
      from: Data(contentsOf: url)
    )
    guard document.streamKey == stream else {
      throw ChartAnnotationStoreError.wrongStream
    }
    guard document.isValid(registry: registry) else {
      throw ChartAnnotationStoreError.invalidDocument
    }
    return document
  }

  func load(
    stream: ChartStreamKey,
    preserving fallback: ChartAnnotationDocument,
    registry: ChartDrawingToolRegistry = .standard
  ) -> ChartAnnotationDocument {
    (try? load(stream: stream, registry: registry)) ?? fallback
  }

  func fileURL(for stream: ChartStreamKey) -> URL {
    let safe = "\(stream.symbol)-\(stream.interval)".map {
      $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_"
    }
    return directoryURL
      .appendingPathComponent(String(safe))
      .appendingPathExtension("chart-annotations.json")
  }
}
