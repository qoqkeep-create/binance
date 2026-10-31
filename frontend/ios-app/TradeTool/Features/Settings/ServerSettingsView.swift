import SwiftUI

struct ServerSettingsView: View {
    @EnvironmentObject private var runtime: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var selected: AppServer?
    @State private var results: [String: ServerNetworkResult] = [:]
    @State private var errors: [String: String] = [:]
    @State private var isTesting = false
    @State private var switchError: String?

    private var selection: AppServer { selected ?? runtime.currentServer }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("选择服务器")
                        .font(BinanceTheme.Typography.text(.title3, weight: .semibold))
                        .foregroundStyle(BinanceTheme.primaryText)

                    VStack(spacing: 1) {
                        ForEach(runtime.servers) { server in
                            serverRow(server)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button {
                        Task { await testNetwork() }
                    } label: {
                        HStack {
                            if isTesting { ProgressView().tint(BinanceTheme.accentText) }
                            Text(isTesting ? "正在测试网络…" : "测试网络响应")
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .foregroundStyle(BinanceTheme.accentText)
                    .disabled(isTesting || runtime.isSwitching)
                    .accessibilityIdentifier("server.testNetwork")

                    Text("测量当前设备到各服务器的响应时间，显示 3 次请求的中位数。")
                        .font(BinanceTheme.Typography.text(.caption))
                        .foregroundStyle(BinanceTheme.secondaryText)

                    Button {
                        Task { await switchServer() }
                    } label: {
                        if runtime.isSwitching {
                            ProgressView().tint(BinanceTheme.onAccent)
                        } else {
                            Text("切换并重新载入")
                        }
                    }
                    .buttonStyle(BinancePrimaryButtonStyle())
                    .disabled(selection == runtime.currentServer || isTesting || runtime.isSwitching)
                    .accessibilityIdentifier("server.switch")

                    Text("切换成功后会重新加载应用。两台服务器的账号和数据各自独立，首次连接需要登录。")
                        .font(BinanceTheme.Typography.text(.caption))
                        .foregroundStyle(BinanceTheme.secondaryText)

                    if let switchError {
                        Text(switchError)
                            .font(BinanceTheme.Typography.text(.subheadline))
                            .foregroundStyle(BinanceTheme.negative)
                            .accessibilityIdentifier("server.switchError")
                    }
                }
                .padding(20)
            }
            .background(BinanceTheme.marketBackground.ignoresSafeArea())
            .navigationTitle("切换服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .disabled(runtime.isSwitching)
                }
            }
        }
        .interactiveDismissDisabled(runtime.isSwitching)
    }

    private func serverRow(_ server: AppServer) -> some View {
        Button {
            selected = server
            switchError = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selection == server ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == server ? BinanceTheme.accentText : BinanceTheme.secondaryText)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(server.name)
                            .font(BinanceTheme.Typography.settingsRowTitle)
                        if runtime.currentServer == server {
                            Text("当前")
                                .font(BinanceTheme.Typography.text(.caption2))
                                .foregroundStyle(BinanceTheme.accentText)
                        }
                    }
                    Text(server.address)
                        .font(BinanceTheme.Typography.text(.caption))
                        .foregroundStyle(BinanceTheme.secondaryText)
                    if let result = results[server.id] {
                        Text("可连接 · \(Int(result.medianMilliseconds.rounded())) ms")
                            .foregroundStyle(BinanceTheme.accentText)
                            .font(BinanceTheme.Typography.text(.caption))
                            .accessibilityIdentifier("server.result.\(server.name)")
                    } else if let error = errors[server.id] {
                        Text(error)
                            .foregroundStyle(BinanceTheme.negative)
                            .font(BinanceTheme.Typography.text(.caption))
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(BinanceTheme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(BinanceTheme.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(runtime.isSwitching)
        .accessibilityIdentifier("server.option.\(server.name)")
    }

    private func testNetwork() async {
        isTesting = true
        defer { isTesting = false }
        results = [:]
        errors = [:]
        for server in runtime.servers {
            do {
                results[server.id] = try await ServerNetworkProbe().check(server, samples: 3)
            } catch {
                errors[server.id] = error.localizedDescription
            }
        }
    }

    private func switchServer() async {
        switchError = nil
        do {
            try await runtime.switchServer(to: selection)
        } catch {
            switchError = "切换失败：\(error.localizedDescription)"
        }
    }
}
