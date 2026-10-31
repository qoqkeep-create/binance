import SwiftUI

struct USDTCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(BinanceTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct USDTMetric: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(BinanceTheme.secondaryText)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.subheadline)
    }
}

struct USDTField: View {
    let title: String
    @Binding var text: String
    var numeric = false
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(BinanceTheme.secondaryText)
            Group {
                if secure { SecureField(title, text: $text) }
                else { TextField(title, text: $text).keyboardType(numeric ? .decimalPad : .default) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(13).background(BinanceTheme.background, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("usdt.field.\(title)")
        }
    }
}

struct USDTEmptyState: View {
    let title: String
    let error: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: error.isEmpty ? "tray" : "wifi.exclamationmark").font(.largeTitle)
            Text(error.isEmpty ? title : error).font(.subheadline).multilineTextAlignment(.center)
            if !error.isEmpty { Button("重新加载", action: retry).buttonStyle(.bordered) }
        }.foregroundStyle(BinanceTheme.secondaryText).frame(maxWidth: .infinity).padding(.vertical, 44)
    }
}

struct USDTNotice: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.footnote).foregroundStyle(BinanceTheme.secondaryText)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(BinanceTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("usdt.notice")
        }
    }
}

extension View {
    func usdtPage(_ title: String) -> some View {
        self.background(BinanceTheme.background.ignoresSafeArea())
            .foregroundStyle(BinanceTheme.primaryText)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
