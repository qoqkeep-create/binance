import SwiftUI

struct USDTStrategiesView: View {
  var returnAfterSelection = false
  var onClose: (() -> Void)? = nil
  var onSelection: ((JSONValue?) -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: USDTStore
  @State private var notice = ""
  @State private var selected: JSONValue = .null
  @State private var selecting = false
  @State private var deleting = false
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Button {
          selected = .null
          selecting = true
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "hand.tap").font(.system(size: 20)).foregroundStyle(WebTheme.brand)
            VStack(alignment: .leading, spacing: 6) {
              Text("手动止盈").font(.system(size: 18, weight: .medium)).foregroundStyle(WebTheme.text)
              Text("自行决定止盈时机，保留止损保护").font(.system(size: 13)).foregroundStyle(WebTheme.secondary)
            }
            Spacer(minLength: 0)
            if store.activeStrategy == nil { Image(systemName: "checkmark").foregroundStyle(WebTheme.brand) }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityIdentifier("strategy.manual")
        ForEach(Array(store.strategies.enumerated()), id: \.offset) { _, strategy in
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
              Button {
                selected = strategy
                selecting = true
              } label: {
                Text(strategy.value("name")).font(.system(size: 18, weight: .medium)).frame(
                  maxWidth: .infinity, alignment: .leading)
              }
              Button {
                selected = strategy
                deleting = true
              } label: {
                WebIcon("trash", size: 16).foregroundStyle(WebTheme.danger).frame(
                  width: 28, height: 28)
              }
              NavigationLink {
                USDTStrategyEditor(strategy: strategy)
              } label: {
                WebIcon("square.and.pencil", size: 16).foregroundStyle(WebTheme.secondary).frame(
                  width: 28, height: 28)
              }
            }
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array((strategy["levels"]?.rows ?? []).enumerated()), id: \.offset) {
                index, level in
                Text(WebStrategyText.level(level, index: index)).font(.system(size: 14))
                  .foregroundStyle(WebTheme.secondary)
              }
            }.onTapGesture {
              selected = strategy
              selecting = true
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
            WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)
          ).overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
        }
        NavigationLink {
          USDTStrategyEditor(strategy: nil)
        } label: {
          Text("新建策略")
        }.buttonStyle(WebButtonStyle(height: 52, radius: 14))
        USDTNotice(text: notice)
      }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
    }.scrollIndicators(.hidden).usdtPage("我的策略", backAction: onClose).task { await store.refresh() }
      .webModal(isPresented: $selecting) {
        WebModal(title: "确认选择策略") {
          Text(selected == .null ? "确定选择手动止盈吗？此设置用于后续开仓。" : "确定要选择策略 \(selected.value("name")) 吗？").foregroundStyle(WebTheme.secondary)
          HStack(spacing: 12) {
            Button("取消") { selecting = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("确认选择") {
              selecting = false
              mutate("set-active")
            }.buttonStyle(WebButtonStyle(radius: 14))
          }
        }
      }
      .webModal(isPresented: $deleting) {
        WebModal(title: "确认删除") {
          Text("确定要删除这个策略吗？").foregroundStyle(WebTheme.secondary)
          HStack(spacing: 12) {
            Button("取消") { deleting = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("删除") {
              deleting = false
              mutate("delete")
            }.buttonStyle(WebButtonStyle(kind: .danger, radius: 14))
          }
        }
      }
  }
  private func mutate(_ action: String) {
    Task {
      do {
        _ = try await store.send("/v1/strategy/" + action,
          selected == .null && action == "set-active" ? ["manual": .bool(true)] : ["strategy_id": selected["id"] ?? .null])
        await store.refresh()
        if action == "set-active" && returnAfterSelection {
          onSelection?(selected == .null ? nil : selected)
          if let onClose { onClose() } else { dismiss() }
        }
      } catch { notice = error.localizedDescription }
    }
  }
}

private struct USDTStrategyLevel: Identifiable {
  let id = UUID()
  var profit = "1"
  var reduce = "20"
  var stopType = "none"
  var stopValue = "0"
  var payload: JSONValue {
    var result: [String: JSONValue] = [
      "profitRR": .string(profit), "reducePosition": .string(reduce),
      "stopLossType": .string(stopType),
    ]
    if stopType == "fixedRR" { result["stopLossRR"] = .string(stopValue) }
    if stopType == "absoluteRR" { result["stopLossAbsoluteRR"] = .string(stopValue) }
    return .object(result)
  }
}

struct USDTStrategyEditor: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.dismiss) private var dismiss
  let strategy: JSONValue?
  @State private var name = "新策略"
  @State private var editingName = false
  @State private var levels = [USDTStrategyLevel()]
  @State private var notice = ""
  @State private var busy = false
  @State private var delete = false
  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        Text("说明：R是指基准止损金额，您当前的基准止损金额为\(DisplayNumber.text(store.riskAmount))U").font(.system(size: 14))
          .foregroundStyle(WebTheme.brand).frame(maxWidth: .infinity, alignment: .leading).padding(
            .horizontal, 12
          ).padding(.vertical, 8).background(
            WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        ForEach($levels) { $level in
          levelCard($level)
        }
        if levels.count < 5 {
          Button {
            levels.append(USDTStrategyLevel(profit: String(levels.count + 1)))
          } label: {
            WebLabel("添加层级", "plus")
          }.buttonStyle(WebButtonStyle(kind: .secondary, radius: 14))
        }
        USDTNotice(text: notice)
      }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
    }.scrollIndicators(.hidden)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button(busy ? "保存中…" : "保存策略") { save() }.buttonStyle(
          WebButtonStyle(height: 52, radius: 14)
        ).disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty).padding(16)
          .background(WebTheme.surface)
      }.background(WebTheme.page.ignoresSafeArea()).foregroundStyle(WebTheme.text).toolbar(
        .hidden, for: .navigationBar
      )
      .safeAreaInset(edge: .top, spacing: 0) {
        ZStack {
          WebPageHeader("")
          HStack(spacing: 8) {
            if editingName {
              TextField("策略名称", text: $name).font(.system(size: 18, weight: .bold))
                .multilineTextAlignment(.center).frame(maxWidth: 220).onSubmit {
                  editingName = false
                }.accessibilityIdentifier("strategy.name")
            } else {
              Text(name).font(.system(size: 18, weight: .bold))
              Button {
                editingName = true
              } label: {
                WebIcon("pencil", size: 16).foregroundStyle(WebTheme.muted)
              }.accessibilityLabel("编辑策略名称")
            }
          }.padding(.bottom, 16)
        }
      }.interactivePopGestureEnabled().onAppear {
        guard let strategy else { return }
        name = strategy.value("name")
        levels = (strategy["levels"]?.rows ?? []).map { row in
          USDTStrategyLevel(
            profit: row.value("profitRR"), reduce: row.value("reducePosition"),
            stopType: row.value("stopLossType"),
            stopValue: row.value(
              row.value("stopLossType") == "fixedRR" ? "stopLossRR" : "stopLossAbsoluteRR",
              fallback: "0"))
        }
      }
  }

  private func levelCard(_ binding: Binding<USDTStrategyLevel>) -> some View {
    let index = levels.firstIndex { $0.id == binding.wrappedValue.id } ?? 0
    let remaining =
      100 - levels.prefix(index).reduce(Decimal.zero) { $0 + (Decimal(string: $1.reduce) ?? 0) }
    return USDTCard(radius: 16, spacing: 12) {
      HStack(spacing: 8) {
        Text("L\(index + 1):").font(.system(size: 16, weight: .semibold))
        Text("剩余仓位 \(DisplayNumber.text(remaining))%").font(.system(size: 14))
          .foregroundStyle(WebTheme.brand).padding(.horizontal, 8).padding(.vertical, 2).background(
            WebTheme.brand.opacity(0.1), in: Capsule())
        Spacer()
        if levels.count > 1 {
          Button {
            levels.removeAll { $0.id == binding.wrappedValue.id }
          } label: {
            WebIcon("trash", size: 16).foregroundStyle(WebTheme.danger)
          }
        }
      }
      HStack(spacing: 8) {
        Text("当盈利达到").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
        WebNumberInput(text: binding.profit, suffix: "R")
        Text("时").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
        Spacer()
      }
      Rectangle().fill(WebTheme.border).frame(height: 1)
      WebRadio(selected: (Decimal(string: binding.wrappedValue.reduce) ?? 0) == 0, title: "不减仓") {
        binding.wrappedValue.reduce = "0"
      }
      HStack(spacing: 10) {
        WebRadio(selected: (Decimal(string: binding.wrappedValue.reduce) ?? 0) > 0, title: "减仓") {
          if (Decimal(string: binding.wrappedValue.reduce) ?? 0) == 0 {
            binding.wrappedValue.reduce = "20"
          }
        }
        if (Decimal(string: binding.wrappedValue.reduce) ?? 0) > 0 {
          WebNumberInput(text: binding.reduce, suffix: "%", width: 64)
        }
        Spacer()
      }
      ZStack {
        Rectangle().fill(WebTheme.border).frame(height: 1)
        Text("同时").font(.system(size: 12)).foregroundStyle(WebTheme.muted).padding(.horizontal, 8)
          .background(WebTheme.surface)
      }.padding(.vertical, 6)
      WebRadio(selected: binding.wrappedValue.stopType == "none", title: "不移动止损位") {
        binding.wrappedValue.stopType = "none"
      }
      WebRadio(selected: binding.wrappedValue.stopType != "none", title: "移动止损位") {
        if binding.wrappedValue.stopType == "none" { binding.wrappedValue.stopType = "absoluteRR" }
      }
      if binding.wrappedValue.stopType != "none" {
        HStack(spacing: 8) {
          WebRadio(selected: binding.wrappedValue.stopType == "absoluteRR", title: "移动到") {
            binding.wrappedValue.stopType = "absoluteRR"
          }
          WebNumberInput(text: binding.stopValue, suffix: "R")
          Text("一次").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
          Spacer()
        }.padding(.leading, 24)
        HStack(spacing: 8) {
          WebRadio(selected: binding.wrappedValue.stopType == "fixedRR", title: "当前浮盈减") {
            binding.wrappedValue.stopType = "fixedRR"
          }
          WebNumberInput(text: binding.stopValue, suffix: "R")
          Text("持续").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
          Spacer()
        }.padding(.leading, 24)
      }
    }.overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
  }
  private func save() {
    var previous = Decimal.zero
    var total = Decimal.zero
    for level in levels {
      guard let profit = Decimal(string: level.profit), profit > previous,
        let reduce = Decimal(string: level.reduce), reduce >= 0
      else {
        notice = "层级盈利 R 必须递增，减仓比例不能为负数"
        return
      }
      previous = profit
      total += reduce
    }
    guard total <= 100 else {
      notice = "累计减仓不能超过 100%"
      return
    }
    busy = true
    Task {
      defer { busy = false }
      do {
        var body: [String: JSONValue] = [
          "name": .string(name), "levels": .array(levels.map(\.payload)),
        ]
        body["strategy_id"] = strategy?["id"]
        _ = try await store.send("/v1/strategy/save", body)
        await store.refresh()
        dismiss()
      } catch { notice = error.localizedDescription }
    }
  }
}

struct USDTChartOrderSettingsView: View {
  var body: some View {
    WebTheme.page.ignoresSafeArea().usdtPage("设置")
  }
}

struct USDTLeverageBracketsView: View {
  let symbol: String
  @EnvironmentObject private var store: USDTStore
  @Environment(\.webDismiss) private var dismiss
  @StateObject private var model = USDTPageModel()
  @State private var selected: Int?
  private var options: [JSONValue] {
    Array((model.value["brackets"]?.rows ?? []).filter {
      guard let amount = $0["max_open_amount"]?.decimal else { return false }
      return !amount.isNaN && amount >= 0
    }.sorted {
      let lhs = $0["max_open_amount"]?.decimal ?? 0, rhs = $1["max_open_amount"]?.decimal ?? 0
      return lhs == rhs ? (Int($0.value("leverage")) ?? 0) < (Int($1.value("leverage")) ?? 0) : lhs > rhs
    }.prefix(3))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("杠杆").font(.system(size: 20, weight: .semibold))
          Text(symbol).font(.system(size: 13)).foregroundStyle(WebTheme.muted)
        }
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("关闭杠杆")
      }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("按可开金额显示前三档，选择后用于本币种下一次开仓。实际金额还受止损设置及成交时可用余额限制。")
            .font(.system(size: 13)).foregroundStyle(WebTheme.muted)
          if !store.isBound {
            USDTNotice(text: "请先绑定 Binance API 后查看当前账户的杠杆档位")
          } else if model.loading && model.value.fields.isEmpty {
            ProgressView("正在读取杠杆档位").frame(maxWidth: .infinity).padding(.vertical, 32)
          } else if !model.error.isEmpty || options.isEmpty {
            USDTEmptyState(title: "暂无可用杠杆档位", error: model.error.isEmpty ? "未取得账户可开金额，请刷新后重试" : model.error) { Task { await load() } }
          } else {
            LazyVStack(spacing: 10) {
              ForEach(Array(options.enumerated()), id: \.offset) { _, row in
                Button { selected = Int(row.value("leverage")) } label: {
                USDTCard(radius: 12, padding: 16) {
                  HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("杠杆").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
                      Text(row.value("leverage") + "×")
                        .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(WebTheme.brand)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                      Text("可开金额").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
                      Text(DisplayNumber.text(row.value("max_open_amount")) + " USDT")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.65)
                    }
                    Image(systemName: selected == Int(row.value("leverage")) ? "checkmark.circle.fill" : "circle")
                      .font(.system(size: 22)).foregroundStyle(selected == Int(row.value("leverage")) ? WebTheme.brand : WebTheme.muted)
                  }
                }.overlay {
                  RoundedRectangle(cornerRadius: 12).stroke(selected == Int(row.value("leverage")) ? WebTheme.brand : WebTheme.border, lineWidth: 1)
                }.accessibilityElement(children: .combine)
                }.buttonStyle(.plain).accessibilityValue(selected == Int(row.value("leverage")) ? "已选中" : "未选中")
                  .accessibilityIdentifier("chart-leverage.bracket." + row.value("leverage"))
              }
            }
          }
        }.padding(16)
      }.scrollIndicators(.hidden)
      Button("确定") {
        if let selected { store.selectLeverage(selected, for: symbol) }
        dismiss()
      }.disabled(selected == nil)
        .buttonStyle(WebButtonStyle(height: 48, radius: 12))
        .accessibilityIdentifier("chart-leverage.confirm")
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
        .background(WebTheme.page)
    }.foregroundStyle(WebTheme.text).background(WebTheme.page.ignoresSafeArea())
      .accessibilityElement(children: .contain).accessibilityIdentifier("chart-leverage")
      .task(id: "\(store.scope):\(store.isBound):\(symbol)") { await load() }
  }

  private func load() async {
    selected = nil
    guard store.isBound else { model.reset(); return }
    await model.load(store, path: "/v1/trade/leverage-brackets", query: [.init(name: "symbol", value: symbol)])
    let available = options.compactMap { Int($0.value("leverage")) }
    selected = store.selectedLeverage(for: symbol).flatMap { available.contains($0) ? $0 : nil } ?? available.first
  }
}

/// Wording shared by the Web strategy cards, picker, and execution log.
enum WebStrategyText {
  static func level(_ value: JSONValue, index: Int) -> String {
    var parts = ["L\(index + 1)：当 RR≥" + DisplayNumber.text(value.value("profitRR", fallback: "0"))]
    if (value["reducePosition"]?.decimal ?? 0) > 0 {
      parts.append("卖出 " + DisplayNumber.text(value.value("reducePosition")) + "%")
    }
    if value.value("stopLossType") == "absoluteRR" {
      parts.append("止损位移动到 " + DisplayNumber.text(value.value("stopLossAbsoluteRR", fallback: "0")) + "R 处")
    }
    if value.value("stopLossType") == "fixedRR" {
      parts.append("止损位移动到浮盈- " + DisplayNumber.text(value.value("stopLossRR", fallback: "0")) + "R 处")
    }
    return parts.joined(separator: "，")
  }
}

struct WebStrategyPicker: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.webDismiss) private var dismiss
  @Binding var selection: String
  @Binding var enabled: Bool
  var autoOnly = false
  var busy = false
  var notice = ""
  let confirmed: () -> Void
  @State private var manage = false
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottom) {
        WebModalBackdrop()
        VStack(spacing: 0) {
          HStack {
            Text("止盈止损策略").font(.system(size: 18, weight: .bold))
            Spacer()
            Button {
              dismiss()
            } label: {
              WebIcon("x", size: 20).padding(4)
            }.accessibilityLabel("关闭")
          }.padding(16).background(WebTheme.surface)
          Rectangle().fill(WebTheme.border).frame(height: 1)
          ScrollView {
            VStack(spacing: 16) {
              if !autoOnly {
                HStack {
                  Text("手动止盈").fontWeight(.medium)
                  Spacer()
                  WebRadio(selected: !enabled, title: "") { enabled = false }
                }.padding(.bottom, 12)
                Rectangle().fill(WebTheme.border).frame(height: 1)
                HStack {
                  Text("自动止盈").fontWeight(.medium)
                  Spacer()
                  WebRadio(selected: enabled, title: "") { enabled = true }
                }
              }
              if store.strategies.isEmpty {
                Text("暂无策略").font(.system(size: 14)).foregroundStyle(WebTheme.muted).frame(
                  maxWidth: .infinity, alignment: .leading
                ).padding(16).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16))
              }
              ForEach(Array(store.strategies.enumerated()), id: \.offset) { _, strategy in
                Button {
                  selection = strategy.value("id")
                  enabled = true
                } label: {
                  VStack(alignment: .leading, spacing: 12) {
                    Text(strategy.value("name")).font(.system(size: 16, weight: .medium))
                    VStack(alignment: .leading, spacing: 6) {
                      ForEach(Array((strategy["levels"]?.rows ?? []).enumerated()), id: \.offset) {
                        index, level in
                        Text(WebStrategyText.level(level, index: index)).font(.system(size: 14))
                          .foregroundStyle(WebTheme.secondary)
                      }
                    }
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
                    WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)
                  ).overlay {
                    RoundedRectangle(cornerRadius: 16).stroke(
                      enabled && selection == strategy.value("id")
                        ? WebTheme.brand : WebTheme.border, lineWidth: 1)
                  }
                }.buttonStyle(.plain)
              }
              Button("添加/编辑策略") { manage = true }.font(.system(size: 16)).foregroundStyle(
                Color(red: 74 / 255, green: 158 / 255, blue: 255 / 255)
              ).frame(maxWidth: .infinity).padding(.vertical, 4)
              USDTNotice(text: notice)
            }.padding(16)
          }.fixedSize(horizontal: false, vertical: true).frame(
            maxHeight: geometry.size.height * 0.6
          ).scrollIndicators(.hidden)
          Button(busy ? "处理中..." : "确定", action: confirmed).buttonStyle(
            WebButtonStyle(height: 52, radius: 14)
          ).disabled(busy || ((enabled || autoOnly) && selection.isEmpty)).padding(.horizontal, 16)
            .padding(.bottom, 24)
        }.font(.system(size: 16)).foregroundStyle(WebTheme.text).background(
          WebTheme.color(0xF8FAFC, 0x272F3A)
        ).clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)).frame(
          maxWidth: 448
        ).padding(.bottom, -geometry.safeAreaInsets.bottom).webModalCard()
      }
    }.presentationBackground(.clear).buttonStyle(.plain).webModalDismissDisabled(busy)
      .webSheet(isPresented: $manage) {
        NavigationStack { USDTStrategiesView(onClose: { manage = false }) }
      }
  }
}
