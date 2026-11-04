import SwiftUI

enum AppTab: Hashable, CaseIterable, Identifiable {
  case markets
  case positions
  case signals
  case reference
  case settings

  var id: Self { self }

  static func availableTabs(
    canViewReferenceNotifications: Bool
  ) -> [AppTab] {
    return [.markets, .positions, .signals, .settings]
  }

  var title: String {
    switch self {
    case .markets:
      return "行情"
    case .positions:
      return "持仓"
    case .signals:
      return "信号"
    case .reference:
      return "参考"
    case .settings:
      return "我的"
    }
  }

  var icon: String {
    switch self {
    case .markets:
      return "chart.bar.fill"
    case .positions:
      return "briefcase"
    case .signals:
      return "bell"
    case .reference:
      return "bookmark"
    case .settings:
      return "person.crop.circle"
    }
  }

  var selectedIcon: String {
    switch self {
    case .markets:
      return "chart.bar.fill"
    case .positions:
      return "briefcase.fill"
    case .signals:
      return "bell.fill"
    case .reference:
      return "bookmark.fill"
    case .settings:
      return "person.crop.circle.fill"
    }
  }
}

struct BottomNavigationBar: View {
  @Binding var selection: AppTab
  let tabs: [AppTab]
  let hasUnreadSignals: Bool

  init(
    selection: Binding<AppTab>,
    tabs: [AppTab] = AppTab.availableTabs(canViewReferenceNotifications: false),
    hasUnreadSignals: Bool = false
  ) {
    _selection = selection
    self.tabs = tabs
    self.hasUnreadSignals = hasUnreadSignals
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs) { tab in
        navigationButton(for: tab)
      }
    }
    .padding(.horizontal, 0)
    .padding(
      .top,
      2
    )
    .padding(
      .bottom,
      8
    )
    .background {
      WebTheme.color(0xFFFFFF, 0x212731)
        .ignoresSafeArea(edges: .bottom)
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WebTheme.border)
        .frame(
          height:
            1
        )
    }
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }

  private func navigationButton(for tab: AppTab) -> some View {
    let isSelected = selection == tab

    return Button {
      guard selection != tab else { return }
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        selection = tab
      }
    } label: {
      VStack(
        spacing: 2
      ) {
        WebNavigationIcon(tab: tab).frame(width: 29, height: 29)
          .overlay(alignment: .topTrailing) {
            if tab == .signals && hasUnreadSignals {
              Circle().fill(Color.red).frame(width: 16, height: 16)
                .overlay { Circle().stroke(WebTheme.color(0xFFFFFF, 0x212731), lineWidth: 1.5) }
                .offset(x: 3, y: -1)
                .accessibilityHidden(true)
            }
          }

        Text(tab.title)
          .font(
            .system(
              size: 12,
              weight: .regular
            )
          )
      }
      .foregroundStyle(
        isSelected
          ? WebTheme.color(0xF0B90B, 0xF0B90B, leadLight: 0x58B9EF)
          : WebTheme.color(0x6B7280, 0x929AA5)
      )
      .frame(maxWidth: .infinity)
      .frame(minHeight: 49)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.title)
    .accessibilityValue(tab == .signals && hasUnreadSignals ? "有未读信号" : "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview {
  VStack(spacing: 0) {
    Spacer()
    BottomNavigationBar(selection: .constant(.markets))
  }
  .background(BinanceTheme.background)
  .preferredColorScheme(.dark)
}

/// Original Web SVG navigation marks, rendered as native vector paths.
private struct WebNavigationIcon: View {
  let tab: AppTab
  var body: some View {
    if let data = Self.paths[tab] {
      WebSVGPath(data: data).fill()
    } else {
      Image(systemName: tab.icon).font(.system(size: 25, weight: .regular))
    }
  }
  private static let paths: [AppTab: String] = [
    .positions:
      "M976.896 883.712q0 19.456-6.656 36.352t-18.944 29.696-28.672 19.968-35.84 7.168l-743.424 0q-19.456 0-36.864-7.168t-30.72-19.968-20.992-29.696-7.68-36.352l0-510.976q0-38.912 27.136-66.048t66.048-27.136l743.424 0q38.912 0 66.048 27.136t27.136 66.048l0 139.264-232.448 0q-38.912 0-66.048 26.624t-27.136 65.536q1.024 26.624 11.264 47.104 8.192 17.408 27.136 31.744t54.784 14.336l232.448 0 0 186.368zM837.632 232.448l-464.896 0q55.296-28.672 104.448-55.296 43.008-22.528 84.992-45.056t65.536-34.816q35.84-19.456 64-17.92t47.616 9.728q22.528 11.264 38.912 29.696zM698.368 604.16q0-19.456 13.312-32.768t32.768-13.312 32.768 13.312 13.312 32.768-13.312 33.28-32.768 13.824-32.768-13.824-13.312-33.28z",
    .markets:
      "M281.6 414.208H81.92c-22.528 0-40.96 18.432-40.96 40.96V921.6c0 22.528 18.432 40.96 40.96 40.96h199.68c22.528 0 40.96-18.432 40.96-40.96V455.168c0-22.528-18.432-40.96-40.96-40.96zM610.304 61.44H413.696c-22.528 0-40.96 18.432-40.96 40.96v819.2c0 22.528 18.432 40.96 40.96 40.96h196.096c22.528 0 40.96-18.432 40.96-40.96V102.4c0.512-22.528-17.92-40.96-40.448-40.96zM942.08 616.448h-199.68c-22.528 0-40.96 18.432-40.96 40.96V921.6c0 22.528 18.432 40.96 40.96 40.96h199.68c22.528 0 40.96-18.432 40.96-40.96v-264.192c0-22.528-18.432-40.96-40.96-40.96z",
    .signals: "M576 64 192 608h236.8L384 960l448-544H595.2L576 64z",
    .settings:
      "M508.995513 0c-281.106911 0-508.995513 227.888602-508.995513 508.995513s227.888602 508.995513 508.995513 508.995512 508.995513-227.888602 508.995512-508.995512c0-281.121049-227.888602-508.995513-508.995512-508.995513z m0 954.946275c-121.550956 0-231.677791-48.679765-312.113221-127.545792 20.359821-133.568906 124.081795-239.623776 256.5196-263.122402-68.827504-23.159296-118.468706-88.084501-118.468706-164.716604 0-96.044625 77.862175-173.892661 173.892661-173.892661 96.044625 0 173.892661 77.862175 173.892662 173.892661 0 76.632102-49.641201 141.557308-118.468706 164.716604 132.536776 23.512765 236.315305 129.694884 256.562016 263.391039-80.407152 78.710501-190.420877 127.277156-311.816306 127.277155z",
  ]
}

struct WebSVGPath: Shape {
  let data: String
  var viewBox: CGFloat = 1024
  func path(in rect: CGRect) -> Path {
    let pattern = "[a-zA-Z]|-?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?"
    let regex = try! NSRegularExpression(pattern: pattern)
    let values = regex.matches(in: data, range: NSRange(data.startIndex..., in: data)).map {
      String(data[Range($0.range, in: data)!])
    }
    var path = Path()
    var point = CGPoint.zero
    var origin = CGPoint.zero
    var control = CGPoint.zero
    var index = 0
    var command = "M"
    func next() -> CGFloat {
      defer { index += 1 }
      return CGFloat(Double(values[index]) ?? 0)
    }
    func position(_ relative: Bool) -> CGPoint {
      let x = next()
      let y = next()
      return CGPoint(x: x + (relative ? point.x : 0), y: y + (relative ? point.y : 0))
    }
    while index < values.count {
      if values[index].first?.isLetter == true {
        command = values[index]
        index += 1
        if command.lowercased() == "z" {
          path.closeSubpath()
          point = origin
          continue
        }
      }
      guard index < values.count else { break }
      let relative = command == command.lowercased()
      switch command.lowercased() {
      case "m":
        point = position(relative)
        path.move(to: point)
        origin = point
        command = relative ? "l" : "L"
      case "l":
        point = position(relative)
        path.addLine(to: point)
      case "h":
        point.x = next() + (relative ? point.x : 0)
        path.addLine(to: point)
      case "v":
        point.y = next() + (relative ? point.y : 0)
        path.addLine(to: point)
      case "q":
        let c = position(relative)
        let end = position(relative)
        path.addQuadCurve(to: end, control: c)
        control = c
        point = end
      case "t":
        let c = CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
        let end = position(relative)
        path.addQuadCurve(to: end, control: c)
        control = c
        point = end
      case "c":
        let c1 = position(relative)
        let c2 = position(relative)
        let end = position(relative)
        path.addCurve(to: end, control1: c1, control2: c2)
        control = c2
        point = end
      case "s":
        let c1 = CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
        let c2 = position(relative)
        let end = position(relative)
        path.addCurve(to: end, control1: c1, control2: c2)
        control = c2
        point = end
      case "a":
        let rx = next()
        let ry = next()
        let rotation = next()
        let large = next() != 0
        let sweep = next() != 0
        let end = position(relative)
        svgArc(
          &path, from: point, to: end, rx: rx, ry: ry, rotation: rotation, large: large,
          sweep: sweep)
        point = end
        control = end
      default: index += 1
      }
    }
    return path.applying(CGAffineTransform(scaleX: rect.width / viewBox, y: rect.height / viewBox))
      .offsetBy(dx: rect.minX, dy: rect.minY)
  }
}

// SVG endpoint arcs are sampled in their original view box before native scaling.
private func svgArc(
  _ path: inout Path, from start: CGPoint, to end: CGPoint, rx: CGFloat, ry: CGFloat,
  rotation: CGFloat, large: Bool, sweep: Bool
) {
  guard start != end, rx != 0, ry != 0 else {
    path.addLine(to: end)
    return
  }
  let phi = rotation * .pi / 180
  let cosPhi = cos(phi)
  let sinPhi = sin(phi)
  let dx = (start.x - end.x) / 2
  let dy = (start.y - end.y) / 2
  let x = cosPhi * dx + sinPhi * dy
  let y = -sinPhi * dx + cosPhi * dy
  var a = abs(rx)
  var b = abs(ry)
  let lambda = x * x / (a * a) + y * y / (b * b)
  if lambda > 1 {
    let scale = sqrt(lambda)
    a *= scale
    b *= scale
  }
  let denominator = a * a * y * y + b * b * x * x
  let factor =
    (large == sweep ? CGFloat(-1) : 1)
    * sqrt(max(0, (a * a * b * b - denominator) / max(denominator, .leastNonzeroMagnitude)))
  let cx = factor * a * y / b
  let cy = factor * -b * x / a
  let centerX = cosPhi * cx - sinPhi * cy + (start.x + end.x) / 2
  let centerY = sinPhi * cx + cosPhi * cy + (start.y + end.y) / 2
  let first = atan2((y - cy) / b, (x - cx) / a)
  var delta = atan2((-y - cy) / b, (-x - cx) / a) - first
  if sweep && delta < 0 { delta += 2 * .pi }
  if !sweep && delta > 0 { delta -= 2 * .pi }
  let segments = max(1, Int(ceil(abs(delta) / (.pi / 32))))
  for i in 1...segments {
    let angle = first + delta * CGFloat(i) / CGFloat(segments)
    path.addLine(
      to: CGPoint(
        x: centerX + cosPhi * a * cos(angle) - sinPhi * b * sin(angle),
        y: centerY + sinPhi * a * cos(angle) + cosPhi * b * sin(angle)))
  }
}
