import SwiftUI
import UIKit

/// Values from the USDT Web theme.css and computed Tailwind styles. CSS px maps to logical pt.
@MainActor enum WebTheme {
  static func color(
    _ light: UInt32, _ dark: UInt32, leadLight: UInt32? = nil, leadDark: UInt32? = nil
  ) -> Color {
    let lead = NativeTradingMode.current == "lead"
    return Color(
      uiColor: UIColor { traits in
        let hex =
          traits.userInterfaceStyle == .dark
          ? (lead ? leadDark ?? dark : dark) : (lead ? leadLight ?? light : light)
        return UIColor(
          red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255, alpha: 1)
      })
  }
  static var page: Color { color(0xF5F5F5, 0x212731, leadLight: 0xF0F6FB) }
  static var surface: Color { color(0xFFFFFF, 0x272F3A) }
  static var input: Color { color(0xF3F4F6, 0x212731) }
  static var secondaryButton: Color { color(0xF3F4F6, 0x2B3441) }
  static var border: Color { color(0xE5E7EB, 0x333B47) }
  static var text: Color { color(0x111827, 0xEAECEF) }
  static var secondary: Color { color(0x4B5563, 0x848E9C) }
  static var muted: Color { color(0x6B7280, 0x848E9C) }
  static var placeholder: Color { color(0x9CA3AF, 0x848E9C) }
  static var brand: Color { color(0xF0B90B, 0xF0B90B, leadLight: 0x58B9EF, leadDark: 0x58B9EF) }
  static var brandEnd: Color { color(0xD9A70A, 0xD9A70A, leadLight: 0x38A5E5, leadDark: 0x38A5E5) }
  static let success = Color(red: 14 / 255, green: 203 / 255, blue: 129 / 255)
  static let danger = Color(red: 246 / 255, green: 70 / 255, blue: 93 / 255)
  static var gradient: LinearGradient {
    LinearGradient(colors: [brand, brandEnd], startPoint: .leading, endPoint: .trailing)
  }
}

struct USDTCard<Content: View>: View {
  var radius: CGFloat = 10
  var padding: CGFloat = 16
  var spacing: CGFloat = 16
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { content }
      .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
      .background(WebTheme.surface, in: RoundedRectangle(cornerRadius: radius))
  }
}

struct USDTMetric: View {
  let title: String
  let value: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).foregroundStyle(WebTheme.muted)
      Spacer(minLength: 0)
      Text(value).foregroundStyle(WebTheme.text).multilineTextAlignment(.trailing)
    }.font(.system(size: 14)).frame(minHeight: 20)
  }
}

struct USDTField: View {
  let title: String
  @Binding var text: String
  var numeric = false
  var secure = false
  var placeholder: String? = nil
  var radius: CGFloat = 10
  var fill: Color? = nil
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !title.isEmpty {
        Text(title).font(.system(size: 14)).foregroundStyle(WebTheme.muted).frame(minHeight: 20)
      }
      Group {
        if secure {
          SecureField(
            placeholder ?? title, text: $text,
            prompt: Text(placeholder ?? title).foregroundColor(WebTheme.placeholder))
        } else {
          TextField(
            placeholder ?? title, text: $text,
            prompt: Text(placeholder ?? title).foregroundColor(WebTheme.placeholder)
          ).keyboardType(numeric ? .decimalPad : .default)
        }
      }
      .font(.system(size: 16)).foregroundStyle(WebTheme.text)
      .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
      .padding(.horizontal, 16).frame(height: 48)
      .background(fill ?? WebTheme.input, in: RoundedRectangle(cornerRadius: radius))
      .overlay {
        RoundedRectangle(cornerRadius: radius).stroke(
          focused ? WebTheme.brand : .clear, lineWidth: 2)
      }
      .accessibilityIdentifier("usdt.field.\(title)")
    }.toolbar {
      if focused {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("完成") { focused = false }
        }
      }
    }
  }
}

struct WebButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, danger, success, text, inactive, charcoal }
  var kind: Kind = .primary
  var height: CGFloat = 48
  var radius: CGFloat = 10
  var fontSize: CGFloat = 16
  var fullWidth = true
  var weight: Font.Weight = .medium
  var mutedDisabled = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: fontSize, weight: weight))
      .foregroundStyle(
        !enabled && mutedDisabled
          ? WebTheme.muted
          : kind == .primary
            ? Color.black
            : kind == .danger || kind == .success || kind == .inactive || kind == .charcoal
              ? Color.white : WebTheme.text
      )
      .padding(.horizontal, fullWidth ? 0 : 12).frame(maxWidth: fullWidth ? .infinity : nil).frame(
        height: height
      )
      .background {
        RoundedRectangle(cornerRadius: radius).fill(
          !enabled && mutedDisabled
            ? AnyShapeStyle(WebTheme.color(0xD1D5DB, 0x2B2F36))
            : kind == .primary
              ? AnyShapeStyle(WebTheme.gradient)
              : AnyShapeStyle(
                kind == .danger
                  ? WebTheme.danger
                  : kind == .success
                    ? WebTheme.success
                    : kind == .text
                      ? Color.clear
                      : kind == .inactive
                        ? WebTheme.color(0x4B5563, 0x4B5563)
                        : kind == .charcoal
                          ? Color(red: 43 / 255, green: 47 / 255, blue: 54 / 255)
                          : WebTheme.secondaryButton))
      }.opacity(
        enabled
          ? configuration.isPressed ? 0.8 : 1
          : mutedDisabled || kind == .inactive ? 1 : kind == .charcoal ? 0.35 : 0.5
      )
      .contentShape(RoundedRectangle(cornerRadius: radius))
  }
}

struct WebSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.label.font(.system(size: 14)).foregroundStyle(WebTheme.muted)
      Spacer(minLength: 0)
      Button {
        configuration.isOn.toggle()
      } label: {
        Capsule().fill(configuration.isOn ? WebTheme.brand : WebTheme.secondaryButton).frame(
          width: 48, height: 28
        )
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(.white).frame(width: 24, height: 24).padding(2).shadow(
            color: .black.opacity(0.12), radius: 2, y: 1)
        }
      }.buttonStyle(.plain).accessibilityLabel(Text(configuration.isOn ? "已开启" : "已关闭"))
        .accessibilityAddTraits(.isButton)
    }
  }
}

struct WebCheckbox: View {
  @Binding var checked: Bool
  var size: CGFloat = 24
  var body: some View {
    Button {
      checked.toggle()
    } label: {
      RoundedRectangle(cornerRadius: size == 16 ? 4 : 8).fill(
        checked ? WebTheme.brand : WebTheme.secondaryButton
      )
      .overlay {
        RoundedRectangle(cornerRadius: size == 16 ? 4 : 8).stroke(
          checked ? WebTheme.brand : WebTheme.border, lineWidth: size == 16 ? 2 : 1)
      }
      .overlay {
        if checked {
          Image(systemName: "checkmark").font(
            .system(size: size == 16 ? 10 : 14, weight: .semibold)
          ).foregroundStyle(.black)
        }
      }
      .frame(width: size, height: size)
    }.buttonStyle(.plain).accessibilityLabel(checked ? "已勾选" : "未勾选").accessibilityValue(
      checked ? "1" : "0")
  }
}

struct WebTabs: View {
  let tabs: [(String, String)]
  @Binding var selection: String
  var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs, id: \.0) { key, title in
        Button {
          selection = key
        } label: {
          Text(title).font(.system(size: 16)).foregroundStyle(
            selection == key ? WebTheme.brand : WebTheme.muted
          )
          .frame(maxWidth: .infinity).frame(height: 44)
          .overlay(alignment: .bottom) {
            if selection == key { Rectangle().fill(WebTheme.brand).frame(height: 2) }
          }
          .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == key ? .isSelected : [])
      }
    }.background(WebTheme.surface).overlay(alignment: .bottom) {
      Rectangle().fill(WebTheme.border).frame(height: 1).offset(y: 1)
    }
  }
}

struct WebForm<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) { content }.padding(16).frame(maxWidth: 448).frame(
        maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden)
    .font(.system(size: 14)).toggleStyle(WebSwitchStyle()).tint(WebTheme.brand)
  }
}

struct WebSection<Content: View>: View {
  var title: String = ""
  @ViewBuilder var content: Content
  init(_ title: String = "", @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }
  var body: some View {
    USDTCard(radius: 12) {
      if !title.isEmpty {
        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(WebTheme.text)
      }
      content
    }
  }
}

struct WebPageHeader<Trailing: View>: View {
  let title: String
  var back = true
  var centered = true
  var height: CGFloat = 60
  var backAction: (() -> Void)?
  @ViewBuilder var trailing: Trailing
  @Environment(\.dismiss) private var dismiss
  init(
    _ title: String, back: Bool = true, centered: Bool = true, height: CGFloat = 60,
    backAction: (() -> Void)? = nil,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) {
    self.title = title
    self.back = back
    self.centered = centered
    self.height = height
    self.backAction = backAction
    self.trailing = trailing()
  }
  var body: some View {
    ZStack {
      if centered {
        Text(title).font(.system(size: 18, weight: .bold)).lineLimit(1).padding(.horizontal, 44)
      }
      HStack(spacing: 8) {
        if back {
          Button {
            if let backAction { backAction() } else { dismiss() }
          } label: {
            WebIcon("chevron-left", size: 20).frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("返回")
        }
        if !centered { Text(title).font(.system(size: 18, weight: .bold)).lineLimit(1) }
        Spacer(minLength: 0)
        trailing
      }
    }.foregroundStyle(WebTheme.text).frame(maxWidth: 448).frame(maxWidth: .infinity).frame(
      height: height == 60 ? 44 : height
    ).padding(.bottom, height == 60 ? 16 : 0).padding(.horizontal, 16)
      .background(WebTheme.surface.ignoresSafeArea(edges: .top))
      .overlay(alignment: .bottom) { Rectangle().fill(WebTheme.border).frame(height: 1) }
  }
}

struct WebModal<Content: View>: View {
  let title: String
  var alignment: Alignment = .center
  var maximumWidth: CGFloat = 384
  var titleSize: CGFloat = 18
  var overlayOpacity: Double = 0.6
  var contentSpacing: CGFloat = 20
  var closeIconSize: CGFloat = 16
  var closeButtonSize: CGFloat = 24
  @Environment(\.webDismiss) private var dismiss
  @ViewBuilder var content: Content
  var body: some View {
    ZStack(alignment: alignment) {
      WebModalBackdrop(opacity: overlayOpacity)
      VStack(alignment: .leading, spacing: contentSpacing) {
        if !title.isEmpty {
          HStack {
            Text(title).font(.system(size: titleSize, weight: .bold))
            Spacer()
            Button {
              dismiss()
            } label: {
              WebIcon("xmark", size: closeIconSize).foregroundStyle(WebTheme.muted).frame(
                width: closeButtonSize, height: closeButtonSize
              ).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("关闭")
          }
        }
        content
      }.font(.system(size: 14)).foregroundStyle(WebTheme.text).padding(24)
        .frame(maxWidth: maximumWidth).background(
          WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)
        ).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, alignment == .bottom ? 8 : 16).webModalCard()
    }.presentationBackground(.clear)
  }
}

struct USDTEmptyState: View {
  let title: String
  let error: String
  let retry: () -> Void
  var body: some View {
    VStack(spacing: 12) {
      Text(error.isEmpty ? title : error).font(.system(size: 16)).multilineTextAlignment(.center)
      if !error.isEmpty {
        Button("重新加载", action: retry).buttonStyle(
          WebButtonStyle(kind: .secondary, height: 36, fontSize: 14, fullWidth: false))
      }
    }.foregroundStyle(WebTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 48)
  }
}

struct USDTNotice: View {
  let text: String
  var body: some View {
    if !text.isEmpty {
      Text(text).font(.system(size: 12)).lineSpacing(4).foregroundStyle(WebTheme.secondary).frame(
        maxWidth: .infinity, alignment: .leading
      ).accessibilityIdentifier("usdt.notice")
    }
  }
}

private struct WebPageModifier: ViewModifier {
  let title: String
  var refresh: (() -> Void)? = nil
  var backAction: (() -> Void)? = nil
  var root: Bool { ["开仓", "持仓", "信号", "我的"].contains(title) }
  func body(content: Content) -> some View {
    content.background(WebTheme.page.ignoresSafeArea()).foregroundStyle(WebTheme.text)
      .font(.system(size: 16)).tint(WebTheme.brand).buttonStyle(.plain)
      .interactivePopGestureEnabled()
      .toolbar(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        if !root {
          WebPageHeader(
            title, centered: !["用户协议", "隐私政策"].contains(title),
            height: title == "日志" ? 56 : 60, backAction: backAction
          ) {
            if let refresh {
              Button(action: refresh) {
                WebIcon("arrow.clockwise", size: 18).foregroundStyle(WebTheme.secondary).frame(
                  width: 36, height: 36)
              }.accessibilityLabel("刷新")
            }
          }
        }
      }
  }
}

extension View {
  func usdtPage(_ title: String, refresh: (() -> Void)? = nil, backAction: (() -> Void)? = nil) -> some View {
    modifier(WebPageModifier(title: title, refresh: refresh, backAction: backAction))
  }
  func webModal<Content: View>(
    isPresented: Binding<Bool>, motion: WebModalMotion? = nil, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    // Observe selected values in the presenting body before the first presentation.
    let modal = content()
    return modifier(WebModalPresenter(isPresented: isPresented, preferredMotion: motion, modal: modal, onDismiss: onDismiss))
  }
}

struct WebRangeSlider: View {
  @Binding var value: Int
  var body: some View {
    GeometryReader { geometry in
      let progress = CGFloat(value - 1) / 24
      ZStack(alignment: .leading) {
        Capsule().fill(WebTheme.border).frame(height: 8)
        Capsule().fill(WebTheme.brand).frame(
          width: max(0, geometry.size.width * progress), height: 8)
        Circle().fill(WebTheme.brand).frame(width: 20, height: 20).overlay {
          Circle().stroke(WebTheme.surface, lineWidth: 3)
        }.shadow(color: WebTheme.brand.opacity(0.3), radius: 4, y: 2).offset(
          x: max(0, (geometry.size.width - 20) * progress))
      }.frame(height: 20).contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { event in
            value = min(
              25, max(1, Int((event.location.x / geometry.size.width * 24).rounded()) + 1))
          })
    }.frame(height: 20).accessibilityElement().accessibilityLabel("止损比例").accessibilityValue(
      "\(value)%"
    ).accessibilityAdjustableAction { direction in
      value = min(25, max(1, value + (direction == .increment ? 1 : -1)))
    }
  }
}

struct WebRadio: View {
  let selected: Bool
  let title: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Circle().stroke(selected ? WebTheme.brand : WebTheme.border, lineWidth: 2).frame(
          width: 16, height: 16
        ).overlay { if selected { Circle().fill(WebTheme.brand).frame(width: 8, height: 8) } }
        Text(title).font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct WebNumberInput: View {
  @Binding var text: String
  var suffix = ""
  var width: CGFloat = 64
  var body: some View {
    HStack(spacing: 2) {
      TextField("", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.center).font(
        .system(size: 14)
      ).accessibilityLabel(suffix.isEmpty ? "数值" : suffix)
      if !suffix.isEmpty {
        Text(suffix).font(.system(size: 14, weight: .medium)).foregroundStyle(WebTheme.brand)
      }
    }.padding(.horizontal, 8).frame(width: width, height: 34).background(
      WebTheme.secondaryButton, in: RoundedRectangle(cornerRadius: 10)
    ).overlay { RoundedRectangle(cornerRadius: 10).stroke(WebTheme.border, lineWidth: 1) }
  }
}

struct WebSelect: View {
  var title: String = ""
  @Binding var selection: String
  let options: [(String, String)]
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !title.isEmpty {
        Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(WebTheme.text)
      }
      Menu {
        ForEach(options, id: \.0) { key, label in Button(label) { selection = key } }
      } label: {
        HStack(spacing: 8) {
          Text(options.first { $0.0 == selection }?.1 ?? "请选择").lineLimit(1)
          Spacer(minLength: 0)
          WebIcon("chevron.down", size: 12)
        }
        .font(.system(size: 14)).foregroundStyle(WebTheme.text).padding(.horizontal, 12).frame(
          height: compact ? 38 : 46
        )
        .background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay {
          RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1)
        }
      }.buttonStyle(.plain).accessibilityLabel(title.isEmpty ? "选择" : title)
    }
  }
}

struct WebTextArea: View {
  var title = ""
  @Binding var text: String
  var placeholder = ""
  var height: CGFloat = 96
  var fontSize: CGFloat = 16
  var labelSize: CGFloat = 14
  var labelWeight: Font.Weight = .medium
  var fill: Color? = nil
  var horizontalPadding: CGFloat = 16
  var verticalPadding: CGFloat = 12
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !title.isEmpty {
        Text(title).font(.system(size: labelSize, weight: labelWeight)).foregroundStyle(
          WebTheme.muted)
      }
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(placeholder).font(.system(size: fontSize)).foregroundStyle(WebTheme.placeholder)
            .padding(
              .horizontal, horizontalPadding
            ).padding(.vertical, verticalPadding)
        }
        TextEditor(text: $text).font(.system(size: fontSize)).foregroundStyle(WebTheme.text)
          .scrollContentBackground(.hidden).padding(.horizontal, max(0, horizontalPadding - 5))
          .padding(.vertical, max(0, verticalPadding - 8)).frame(
            minHeight: height)
      }.background(fill ?? WebTheme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay {
        RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1)
      }
    }
  }
}

/// Keeps the form field's Web dimensions while using the iOS date editor after tapping it.
struct WebDateField: View {
  let title: String
  @Binding var selection: Date
  var includesTime = true
  var latestDate: Date? = nil
  @State private var editing = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 14, weight: .medium)).frame(height: 20)
      Button {
        editing = true
      } label: {
        HStack {
          Text(
            selection.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
              + (includesTime
                ? "  "
                  + selection.formatted(
                    .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) : ""))
          Spacer(minLength: 0)
          Image(systemName: "calendar").font(.system(size: 16))
        }.font(.system(size: 14)).foregroundStyle(WebTheme.text).padding(.horizontal, 12).frame(
          height: 48
        ).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay {
          RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("web.date.\(title)")
    }
    .webModal(isPresented: $editing) {
      WebModal(title: title, maximumWidth: 448) {
        DatePicker(
          title, selection: $selection, in: Date.distantPast...(latestDate ?? .distantFuture),
          displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date]
        ).datePickerStyle(.graphical).labelsHidden().tint(WebTheme.brand)
        Button("确定") { editing = false }.buttonStyle(WebButtonStyle(radius: 14))
      }
    }
  }
}

struct WebBadge: View {
  let text: String
  var color: Color = WebTheme.brand
  var body: some View {
    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(color).padding(
      .horizontal, 6
    ).padding(.vertical, 2).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
  }
}

struct WebDirection: View {
  let long: Bool
  var body: some View {
    Text(long ? "多" : "空").font(.system(size: 12, weight: .medium)).foregroundStyle(.white).frame(
      width: 20, height: 20
    ).background(long ? WebTheme.success : WebTheme.danger, in: RoundedRectangle(cornerRadius: 4))
  }
}

enum WebFormat {
  static func amount(_ value: String, signed: Bool = false) -> String {
    let number = DisplayNumber.text(value, signed: signed)
    return number == "--" ? number : number + " U"
  }
  static func date(_ value: String) -> Date? {
    if let timestamp = Double(value), timestamp > 0 {
      return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp)
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  static func time(_ value: String, format: String = "MM-dd HH:mm") -> String {
    guard let date = date(value) else { return value }
    let output = DateFormatter()
    output.timeZone = TimeZone(identifier: "Asia/Shanghai")
    output.dateFormat = format
    return output.string(from: date)
  }
}

/// Lucide v0.487.0 (ISC), copied from the original Web design's icon nodes.
struct WebIcon: View {
  let name: String
  var size: CGFloat = 20
  init(_ name: String, size: CGFloat = 20) {
    self.name = name
    self.size = size
  }
  var body: some View {
    Group {
      if let data = Self.paths[Self.aliases[name] ?? name] {
        WebSVGPath(data: data, viewBox: 24).stroke(
          style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      } else {
        Image(systemName: name).font(.system(size: size))
      }
    }.frame(width: size, height: size).contentShape(Rectangle())
  }
  private static let aliases: [String: String] = [
    "arrow.up.right": "arrow-up-right",
    "arrow.down.left": "arrow-down-left",
    "chevron.left": "chevron-left",
    "chevron.right": "chevron-right",
    "chevron.down": "chevron-down",
    "chevron.up": "chevron-up",
    "xmark": "x",
    "checkmark": "check",
    "square.and.pencil": "pencil",
    "trash": "trash-2",
    "info.circle": "info",
    "list.clipboard": "clipboard-list",
    "clock.arrow.circlepath": "history",
    "arrow.clockwise": "refresh-cw",
    "chart.line.uptrend.xyaxis": "trending-up",
    "doc.text": "file-text",
    "gearshape": "settings",
    "wallet.bifold": "wallet-cards",
    "paperplane": "send",
    "link": "link-2",
    "rectangle.portrait.and.arrow.right": "log-out",
    "chart.bar.xaxis": "chart-candlestick",
    "sun.max": "sun",
    "envelope": "mail",
  ]
  private static let paths: [String: String] = [
    "arrow-up-right": "M7 7h10v10 M7 17 17 7",
    "arrow-down-left": "M17 7 7 17 M17 17H7V7",
    "chevron-left": "M15 18 l-6-6 6-6",
    "chevron-right": "M9 18 l6-6-6-6",
    "chevron-down": "M6 9 l6 6 6-6",
    "chevron-up": "M18 15 l-6-6-6 6",
    "x": "M18 6 6 18 M6 6 l12 12",
    "check": "M20 6 9 17l-5-5",
    "plus": "M5 12h14 M12 5v14",
    "trash-2":
      "M3 6h18 M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6 M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2 M10 11L10 17 M14 11L14 17",
    "pencil":
      "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z M15 5 l4 4",
    "info": "M2.0 12.0a10.0 10.0 0 1 0 20.0 0a10.0 10.0 0 1 0 -20.0 0 M12 16v-4 M12 8h.01",
    "clipboard-list":
      "M9.0 2.0H15.0Q16.0 2.0 16.0 3.0V5.0Q16.0 6.0 15.0 6.0H9.0Q8.0 6.0 8.0 5.0V3.0Q8.0 2.0 9.0 2.0Z M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2 M12 11h4 M12 16h4 M8 11h.01 M8 16h.01",
    "history": "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8 M3 3v5h5 M12 7v5l4 2",
    "refresh-cw":
      "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8 M21 3v5h-5 M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16 M8 16H3v5",
    "trending-up": "M22 7 13.5 15.5 8.5 10.5 2 17 M16 7 22 7 22 13",
    "target":
      "M2.0 12.0a10.0 10.0 0 1 0 20.0 0a10.0 10.0 0 1 0 -20.0 0 M6.0 12.0a6.0 6.0 0 1 0 12.0 0a6.0 6.0 0 1 0 -12.0 0 M10.0 12.0a2.0 2.0 0 1 0 4.0 0a2.0 2.0 0 1 0 -4.0 0",
    "file-text":
      "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z M14 2v4a2 2 0 0 0 2 2h4 M10 9H8 M16 13H8 M16 17H8",
    "settings":
      "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z M9.0 12.0a3.0 3.0 0 1 0 6.0 0a3.0 3.0 0 1 0 -6.0 0",
    "wallet-cards":
      "M5.0 3.0H19.0Q21.0 3.0 21.0 5.0V19.0Q21.0 21.0 19.0 21.0H5.0Q3.0 21.0 3.0 19.0V5.0Q3.0 3.0 5.0 3.0Z M3 9a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2 M3 11h3c.8 0 1.6.3 2.1.9l1.1.9c1.6 1.6 4.1 1.6 5.7 0l1.1-.9c.5-.5 1.3-.9 2.1-.9H21",
    "send":
      "M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z M21.854 2.147 l-10.94 10.939",
    "bell":
      "M10.268 21a2 2 0 0 0 3.464 0 M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326",
    "link-2": "M9 17H7A5 5 0 0 1 7 7h2 M15 7h2a5 5 0 1 1 0 10h-2 M8 12L16 12",
    "log-out": "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4 M16 17 21 12 16 7 M21 12L9 12",
    "chart-candlestick":
      "M9 5v4 M8.0 9.0H10.0Q11.0 9.0 11.0 10.0V14.0Q11.0 15.0 10.0 15.0H8.0Q7.0 15.0 7.0 14.0V10.0Q7.0 9.0 8.0 9.0Z M9 15v2 M17 3v2 M16.0 5.0H18.0Q19.0 5.0 19.0 6.0V12.0Q19.0 13.0 18.0 13.0H16.0Q15.0 13.0 15.0 12.0V6.0Q15.0 5.0 16.0 5.0Z M17 13v3 M3 3v16a2 2 0 0 0 2 2h16",
    "candlesticks": "M7 3v4 M5 7h4v9H5Z M7 16v5 M17 3v3 M15 6h4v6h-4Z M17 12v7",
    "sun":
      "M8.0 12.0a4.0 4.0 0 1 0 8.0 0a4.0 4.0 0 1 0 -8.0 0 M12 2v2 M12 20v2 M4.93 4.93 l1.41 1.41 M17.66 17.66 l1.41 1.41 M2 12h2 M20 12h2 M6.34 17.66 l-1.41 1.41 M19.07 4.93 l-1.41 1.41",
    "moon": "M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z",
    "eye":
      "M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0 M9.0 12.0a3.0 3.0 0 1 0 6.0 0a3.0 3.0 0 1 0 -6.0 0",
    "mail":
      "M4.0 4.0H20.0Q22.0 4.0 22.0 6.0V18.0Q22.0 20.0 20.0 20.0H4.0Q2.0 20.0 2.0 18.0V6.0Q2.0 4.0 4.0 4.0Z M22 7 l-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7",
    "play": "M6 3 20 12 6 21 6 3Z",
    "database":
      "M3.0 5.0a9.0 3.0 0 1 0 18.0 0a9.0 3.0 0 1 0 -18.0 0 M3 5V19A9 3 0 0 0 21 19V5 M3 12A9 3 0 0 0 21 12",
    "code-2": "M18 16 l4-4-4-4 M6 8 l-4 4 4 4 M14.5 4 l-5 16",
    "book-open":
      "M12 7v14 M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z",
    "circle": "M2.0 12.0a10.0 10.0 0 1 0 20.0 0a10.0 10.0 0 1 0 -20.0 0",
    "check-circle-2": "M2.0 12.0a10.0 10.0 0 1 0 20.0 0a10.0 10.0 0 1 0 -20.0 0 M9 12 l2 2 4-4",
    "circle-check": "M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0 M9 12l2 2 4-4",
    "circle-x": "M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0 M15 9l-6 6 M9 9l6 6",
  ]
}

struct WebLabel: View {
  let title: String
  let icon: String
  init(_ title: String, _ icon: String) {
    self.title = title
    self.icon = icon
  }
  var body: some View {
    HStack(spacing: 6) {
      WebIcon(icon, size: 16)
      Text(title)
    }
  }
}

struct WebFinanceModal<Content: View>: View {
  let title: String
  var icon = "wallet-cards"
  @ViewBuilder var content: Content
  @Environment(\.webDismiss) private var dismiss
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        WebModalBackdrop()
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            WebIcon(icon, size: 22).foregroundStyle(WebTheme.brand)
            Text(title).font(.system(size: 16, weight: .bold))
            Spacer()
            Button {
              dismiss()
            } label: {
              WebIcon("x", size: 19).foregroundStyle(WebTheme.placeholder).padding(8)
            }.accessibilityLabel("关闭")
          }.padding(.horizontal, 20).padding(.vertical, 16)
          Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
          ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(20) }
            .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.white).frame(maxWidth: 384).frame(maxHeight: geometry.size.height * 0.85)
          .background(
            BinanceTheme.surface,
            in: RoundedRectangle(cornerRadius: 10)
          ).padding(16).webModalCard().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.presentationBackground(.clear).preferredColorScheme(.dark)
  }
}

struct WebFinanceRow: View {
  let label: String
  let value: String
  var color: Color = .white
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label).foregroundStyle(WebTheme.secondary)
      Spacer(minLength: 0)
      Text(value).fontWeight(.medium).foregroundStyle(color).multilineTextAlignment(.trailing)
    }.font(.system(size: 14)).padding(.vertical, 12).overlay(alignment: .bottom) {
      Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
    }
  }
}

private struct WebModalCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct WebModalPhaseKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct WebModalOffsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct WebModalUnderlyingKey: EnvironmentKey { static let defaultValue: Double = 0 }
private struct WebModalBaseKey: EnvironmentKey { static let defaultValue: Double = 0 }
private struct WebModalDimmingPreferenceKey: PreferenceKey {
  static var defaultValue = 0.6
  static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}
private struct WebModalOpacityKey: EnvironmentKey { static let defaultValue: Double = 1 }
private struct WebModalDragKey: EnvironmentKey { static let defaultValue: ((CGFloat, Bool) -> Void)? = nil }
private struct WebModalBlockedKey: PreferenceKey {
  static var defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
struct WebDismissAction {
  let close: (() -> Void)?
  let fallback: DismissAction
  func callAsFunction() { if let close { close() } else { fallback() } }
}
extension EnvironmentValues {
  fileprivate var webModalCloseAction: (() -> Void)? {
    get { self[WebModalCloseKey.self] } set { self[WebModalCloseKey.self] = newValue }
  }
  fileprivate var webModalPhase: CGFloat {
    get { self[WebModalPhaseKey.self] } set { self[WebModalPhaseKey.self] = newValue }
  }
  fileprivate var webModalOffset: CGFloat {
    get { self[WebModalOffsetKey.self] } set { self[WebModalOffsetKey.self] = newValue }
  }
  fileprivate var webModalOpacity: Double {
    get { self[WebModalOpacityKey.self] } set { self[WebModalOpacityKey.self] = newValue }
  }
  fileprivate var webModalDrag: ((CGFloat, Bool) -> Void)? {
    get { self[WebModalDragKey.self] } set { self[WebModalDragKey.self] = newValue }
  }
  fileprivate var webModalUnderlying: Double {
    get { self[WebModalUnderlyingKey.self] } set { self[WebModalUnderlyingKey.self] = newValue }
  }
  fileprivate var webModalBase: Double {
    get { self[WebModalBaseKey.self] } set { self[WebModalBaseKey.self] = newValue }
  }
  var webDismiss: WebDismissAction { WebDismissAction(close: self[WebModalCloseKey.self], fallback: dismiss) }
}

struct WebModalBackdrop: View {
  var opacity: Double = 0.6
  var dismissible = true
  @Environment(\.webDismiss) private var dismiss
  @Environment(\.self) private var environment
  var body: some View {
    let base = environment[WebModalBaseKey.self]
    let desired = opacity * Double(environment[WebModalPhaseKey.self])
    // Nested confirmation layers reach the requested total dimming, rather
    // than multiplying two black overlays into an unexpectedly dark screen.
    let alpha = max(0, min(1, (desired - base) / max(0.001, 1 - base)))
    Color.black.opacity(alpha)
      .preference(key: WebModalDimmingPreferenceKey.self, value: opacity)
      .ignoresSafeArea().contentShape(Rectangle()).onTapGesture { if dismissible { dismiss() } }
      .accessibilityIdentifier("modal.backdrop")
  }
}
enum WebModalMotion: Equatable {
  case fade, slide
  static func resolve(cardHeight: CGFloat, containerHeight: CGFloat, reduceMotion: Bool,
    preferred: Self? = nil) -> Self {
    if reduceMotion { return .fade }
    return preferred ?? (cardHeight >= containerHeight * 0.5 ? .slide : .fade)
  }
  var openingDuration: Double { self == .slide ? 0.18 : 0.16 }
}
private struct WebModalCardFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next.height > value.height { value = next }
  }
}
private struct WebModalCard: ViewModifier {
  @Environment(\.self) private var environment
  @State private var top: CGFloat = 0
  @State private var dragging = false
  func body(content: Content) -> some View {
    content.contentShape(Rectangle()).opacity(environment[WebModalOpacityKey.self])
      .offset(y: environment[WebModalOffsetKey.self])
      .background(GeometryReader { geometry in
        Color.clear.preference(key: WebModalCardFrameKey.self, value: geometry.frame(in: .global))
      })
      .onPreferenceChange(WebModalCardFrameKey.self) { top = $0.minY }
      .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .global).onChanged { value in
        if !dragging {
          guard environment[WebModalDragKey.self] != nil,
                value.startLocation.y >= top, value.startLocation.y < top + 80,
                value.translation.height > abs(value.translation.width) else { return }
          dragging = true
        }
        environment[WebModalDragKey.self]?(max(0, value.translation.height), false)
      }.onEnded { value in
        guard dragging else { return }
        dragging = false
        environment[WebModalDragKey.self]?(max(0, value.predictedEndTranslation.height), true)
      })
  }
}

extension View {
  func webModalCard() -> some View { modifier(WebModalCard()) }
  func webModalDismissDisabled(_ disabled: Bool) -> some View {
    preference(key: WebModalBlockedKey.self, value: disabled)
  }
  func webModal<Item: Identifiable, Content: View>(item: Binding<Item?>, motion: WebModalMotion? = nil,
      @ViewBuilder content: @escaping (Item) -> Content) -> some View {
    modifier(WebItemModalPresenter(item: item, preferredMotion: motion, builder: content))
  }
}
private struct WebModalPresenter<Modal: View>: ViewModifier {
  @Binding var isPresented: Bool
  let preferredMotion: WebModalMotion?
  let modal: Modal
  var onDismiss: (() -> Void)?
  @State private var cover = false
  func body(content: Content) -> some View {
    content.fullScreenCover(isPresented: $cover, onDismiss: onDismiss) {
      WebModalStage(isPresented: $isPresented, preferredMotion: preferredMotion, modal: modal) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { cover = false }
      }.presentationBackground(.clear)
    }.onChange(of: isPresented, initial: true) { _, shown in
      if shown {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { cover = true }
      }
    }.onChange(of: cover) { _, shown in
      if !shown { isPresented = false }
    }
  }
}
private struct WebModalStage<Modal: View>: View {
  @Binding var isPresented: Bool
  let preferredMotion: WebModalMotion?
  let modal: Modal
  let finished: () -> Void
  @State private var progress: CGFloat = 0
  @State private var drag: CGFloat = 0
  @State private var blocked = false
  @State private var closing = false
  @State private var overlayOpacity = 0.6
  @Environment(\.webModalUnderlying) private var underlying
  @State private var motion: WebModalMotion?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { geometry in
      modal
        .environment(\.webModalBase, underlying)
        .environment(\.webModalUnderlying, max(underlying, overlayOpacity * Double(progress * max(0, 1 - drag / geometry.size.height))))
        .environment(\.webModalCloseAction, { if !blocked { isPresented = false } })
        .environment(\.webModalPhase, progress * max(0, 1 - drag / geometry.size.height))
        .environment(\.webModalOffset, motion == .slide ? (1 - progress) * geometry.size.height + drag : 0)
        .environment(\.webModalOpacity, motion == .slide ? 1 : Double(progress * max(0, 1 - drag / geometry.size.height)))
        .environment(\.webModalDrag, { amount, ended in
          guard !blocked, !closing else { return }
          if ended {
            if amount > 130 { isPresented = false }
            else { withAnimation(.easeOut(duration: 0.2)) { drag = 0 } }
          } else { drag = amount }
        })
        .onPreferenceChange(WebModalBlockedKey.self) { blocked = $0 }
        .onPreferenceChange(WebModalDimmingPreferenceKey.self) { overlayOpacity = $0 }
        .onPreferenceChange(WebModalCardFrameKey.self) { frame in
          guard motion == nil, frame.height > 0 else { return }
          let selected = WebModalMotion.resolve(cardHeight: frame.height,
            containerHeight: geometry.size.height, reduceMotion: reduceMotion, preferred: preferredMotion)
          motion = selected
          Task { @MainActor in
            await Task.yield()
            guard isPresented, !closing else { return }
            var transaction = Transaction(animation: .easeOut(duration: selected.openingDuration))
            transaction.disablesAnimations = false
            withTransaction(transaction) { progress = 1 }
          }
        }
        .onChange(of: isPresented) { _, shown in
          guard !shown, !closing else { return }
          closing = true
          withAnimation(.easeOut(duration: 0.14), completionCriteria: .logicallyComplete) {
            progress = 0; drag = 0
          } completion: { finished() }
        }
    }
  }
}

/// Large navigation/form panels use the shared fast presentation and header drag dismissal.
struct WebSheet<Content: View>: View {
  var heightFraction: CGFloat = 0.96
  var protectsBottomSafeArea = false
  @ViewBuilder var content: Content
  private var containerBottomInset: CGFloat {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
  }
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottom) {
        WebModalBackdrop(opacity: 0.45)
        VStack(spacing: 0) {
          Capsule().fill(WebTheme.muted.opacity(0.5)).frame(width: 36, height: 5)
            .padding(.vertical, 10).accessibilityHidden(!protectsBottomSafeArea)
            .accessibilityLabel("表单控制柄").accessibilityAddTraits(.isButton)
          content.frame(maxWidth: .infinity, maxHeight: .infinity)
            // Geometry's bottom inset also includes the keyboard; reserve only
            // the window's home-indicator inset so a focused list can still scroll.
            .padding(.bottom, protectsBottomSafeArea ? containerBottomInset : 0)
        }.frame(maxWidth: 720).frame(height: geometry.size.height * heightFraction)
          .background(BinanceTheme.background)
          .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
          .webModalCard()
      }
    }.ignoresSafeArea(.container, edges: .bottom)
  }
}

extension View {
  func webSheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
    webModal(isPresented: isPresented) { WebSheet(content: content) }
  }
  func webSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
    webModal(item: item) { selected in WebSheet { content(selected) } }
  }
}

private struct WebItemModalPresenter<Item: Identifiable, Modal: View>: ViewModifier {
  @Binding var item: Item?
  let preferredMotion: WebModalMotion?
  let builder: (Item) -> Modal
  @State private var previous: Item?
  func body(content: Content) -> some View {
    content.webModal(isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
      motion: preferredMotion) {
      if let selected = item ?? previous { builder(selected) }
    }.onChange(of: item?.id, initial: true) { _, _ in
      if let item { previous = item }
    }
  }
}
