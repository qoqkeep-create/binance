import SwiftUI

struct USDTLegalView: View {
  var document: String = "用户协议"
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text(document).font(.system(size: 20, weight: .bold)).foregroundStyle(WebTheme.text)
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
              .foregroundStyle(WebTheme.muted).frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("关闭")
            .accessibilityIdentifier("auth.legal.close")
        }
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
          VStack(alignment: .leading, spacing: index == 0 ? 12 : 8) {
            Text(section.0).font(.system(size: index == 0 ? 18 : 16, weight: .bold))
              .foregroundStyle(WebTheme.text)
            ForEach(Array(section.1.enumerated()), id: \.offset) { _, paragraph in
              Text(paragraph).font(.system(size: 14)).lineSpacing(6).foregroundStyle(
                WebTheme.secondary
              ).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Rectangle().fill(WebTheme.border).frame(height: 1)
        Text("最后更新日期：2024年1月").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(
        WebTheme.surface, in: RoundedRectangle(cornerRadius: 14)
      ).padding(16).padding(.bottom, 16).frame(maxWidth: 448).frame(maxWidth: .infinity)
    }.scrollIndicators(.hidden).background(BinanceTheme.background)
      .toolbar(.hidden, for: .navigationBar).largeTradingSheet()
  }
  private var sections: [(String, [String])] { document == "隐私政策" ? Self.privacy : Self.agreement }
  private static let agreement: [(String, [String])] = [
    ("欢迎使用Binance Tools", ["在使用本应用前，请您仔细阅读并充分理解本协议各条款。一旦您使用本应用，即表示您已阅读、理解并同意接受本协议的所有内容。"]),
    ("1. 服务说明", ["Binance Tools是一款虚拟货币交易辅助工具，提供持仓管理、交易执行、风险控制等功能。本应用仅作为工具使用，不提供投资建议。"]),
    ("2. 风险提示", ["虚拟货币交易存在极高风险，可能导致全部本金损失。请您根据自身风险承受能力谨慎决策，本应用不对任何交易损失承担责任。"]),
    ("3. 账户安全", ["您应妥善保管账户密码、API密钥等重要信息。因您自身原因导致的账户安全问题，本应用不承担责任。建议您定期更换密码，不要在多个平台使用相同密码。"]),
    ("4. API使用规范", ["在绑定交易所API时，请确保仅授予必要的权限。建议不要授予提币权限，以降低资金风险。本应用承诺不会将您的API信息用于任何未经授权的操作。"]),
    ("5. 数据隐私", ["我们重视您的隐私保护，您的交易数据、持仓信息等将被加密存储。我们不会向第三方出售、出租或以其他方式共享您的个人信息。"]),
    ("6. 服务变更与终止", ["我们保留随时修改、暂停或终止部分或全部服务的权利。如有重大变更，我们将通过应用内通知或其他适当方式提前告知用户。"]),
    ("7. 免责声明", ["本应用提供的所有数据、指标、信号仅供参考，不构成任何投资建议。用户应根据自身情况独立判断，自行承担交易风险。"]),
    ("8. 协议更新", ["我们可能会不定期更新本协议。更新后的协议将在应用内公布，您继续使用本应用即表示同意更新后的协议内容。"]),
  ]
  private static let privacy: [(String, [String])] = [
    ("Binance Tools隐私政策", ["本隐私政策说明了Binance Tools如何收集、使用、存储和保护您的个人信息。我们深知个人信息对您的重要性，会尽全力保护您的个人信息安全。"]),
    (
      "1. 信息收集",
      [
        "我们可能收集以下信息：", "• 账户信息：邮箱地址、用户名、密码（加密存储）", "• 交易数据：持仓记录、交易历史、资产余额",
        "• API信息：交易所API密钥（加密存储）、API别名", "• 设备信息：设备型号、操作系统版本、应用版本", "• 使用数据：功能使用频率、页面访问记录",
      ]
    ),
    (
      "2. 信息使用",
      [
        "我们收集的信息将用于：", "• 提供交易辅助服务和持仓管理功能", "• 执行您的交易指令和风险控制策略", "• 优化应用性能和用户体验", "• 发送重要通知和服务更新",
        "• 进行数据分析以改进服务质量",
      ]
    ),
    ("3. 信息存储", ["您的个人信息将存储在安全的服务器中，采用行业标准的加密技术。敏感信息（如API密钥、密码）采用不可逆加密算法存储。我们会定期进行安全审计，确保数据安全。"]),
    (
      "4. 信息共享",
      [
        "我们承诺不会出售、出租或以其他方式向第三方共享您的个人信息，除非：", "• 获得您的明确授权", "• 法律法规要求或政府部门要求", "• 为维护您的重大合法权益",
        "• 与交易所API进行必要的数据交互（仅限交易执行）",
      ]
    ),
    (
      "5. Cookie使用", ["我们使用Cookie和类似技术来改善用户体验，包括记住您的登录状态、主题偏好等。您可以在浏览器设置中管理Cookie，但这可能影响部分功能的正常使用。"]
    ),
    (
      "6. 您的权利",
      [
        "您对个人信息享有以下权利：", "• 访问权：查看您的个人信息", "• 更正权：修改不准确的个人信息", "• 删除权：要求删除您的个人信息",
        "• 撤回权：撤回已授予的信息处理同意", "• 导出权：获取您的个人信息副本",
      ]
    ),
    ("7. 未成年人保护", ["本应用不向18岁以下的未成年人提供服务。如果我们发现收集了未成年人的信息，将立即删除相关数据。"]),
    ("8. 政策更新", ["我们可能会不时更新本隐私政策。更新后的政策将在应用内公布，重大变更将通过显著方式通知您。继续使用本应用即表示您同意更新后的政策。"]),
    ("9. 联系我们", ["如果您对本隐私政策有任何疑问、意见或建议，或需要行使您的权利，请通过应用内反馈功能或邮件联系我们。"]),
  ]
}
