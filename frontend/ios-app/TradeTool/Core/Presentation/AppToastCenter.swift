import SwiftUI

enum AppToastStyle {
    case success
    case error
    case warning
    case info
}

struct AppToast: Identifiable {
    static let defaultDuration: TimeInterval = 1.5

    let id = UUID()
    let title: String
    let message: String
    let style: AppToastStyle
    let iconSystemName: String?
    let duration: TimeInterval

    init(
        title: String,
        message: String,
        style: AppToastStyle,
        iconSystemName: String? = nil,
        duration: TimeInterval = AppToast.defaultDuration
    ) {
        self.title = title
        self.message = message
        self.style = style
        self.iconSystemName = iconSystemName
        self.duration = duration
    }
}

@MainActor
final class AppToastCenter: ObservableObject, APIErrorReporting {
    @Published private(set) var activeToast: AppToast?

    private var dismissalTask: Task<Void, Never>?

    func report(_ error: APIError) {
        present(
            error.userMessage,
            title: error.presentationTitle,
            style: .error
        )
    }

    func present(
        _ message: String,
        title: String = "提示",
        style: AppToastStyle = .info,
        iconSystemName: String? = nil,
        duration: TimeInterval = AppToast.defaultDuration
    ) {
        dismissalTask?.cancel()

        let resolvedDuration = duration.isFinite
            ? max(duration, 0.5)
            : AppToast.defaultDuration

        let toast = AppToast(
            title: title,
            message: Self.compactMessage(message),
            style: style,
            iconSystemName: iconSystemName,
            duration: resolvedDuration
        )

        withAnimation(.snappy(duration: 0.25)) {
            activeToast = toast
        }

        let nanoseconds = UInt64(resolvedDuration * 1_000_000_000)
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else {
                    return
                }
                self?.dismiss()
            } catch {
                return
            }
        }
    }

    func success(_ message: String, title: String = "操作成功") {
        present(message, title: title, style: .success)
    }

    func warning(_ message: String, title: String = "请注意") {
        present(message, title: title, style: .warning)
    }

    func error(_ message: String, title: String = "操作失败") {
        present(message, title: title, style: .error)
    }

    func dismiss() {
        dismissalTask?.cancel()
        dismissalTask = nil

        withAnimation(.easeOut(duration: 0.18)) {
            activeToast = nil
        }
    }

    private static func compactMessage(_ message: String) -> String {
        let normalized = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？，,;；"))

        return normalized.isEmpty ? "提示" : normalized
    }
}

private struct GlobalAPIToastModifier: ViewModifier {
    @ObservedObject var toastCenter: AppToastCenter

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                Color.clear

                if let toast = toastCenter.activeToast {
                    ToastView(toast: toast)
                        .transition(
                            .scale(scale: 0.92)
                                .combined(with: .opacity)
                        )
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .all)
            .ignoresSafeArea(.keyboard, edges: .all)
            .allowsHitTesting(false)
        }
    }
}

private struct ToastView: View {
    let toast: AppToast

    var body: some View {
        VStack(spacing: toast.iconSystemName == nil ? 0 : 10) {
            if let iconSystemName = toast.iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, toast.iconSystemName == nil ? 18 : 20)
        .padding(.vertical, toast.iconSystemName == nil ? 14 : 20)
        .frame(
            minWidth: toast.iconSystemName == nil ? 0 : 112,
            maxWidth: 180
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("app.toast")
    }
}

extension View {
    func globalAPIToasts(
        using toastCenter: AppToastCenter
    ) -> some View {
        modifier(GlobalAPIToastModifier(toastCenter: toastCenter))
    }
}

#Preview {
    ZStack {
        BinanceTheme.background.ignoresSafeArea()

        VStack(spacing: 16) {
            ToastView(
                toast: AppToast(
                    title: "提示",
                    message: "复制成功",
                    style: .info,
                    duration: AppToast.defaultDuration
                )
            )

            ToastView(
                toast: AppToast(
                    title: "操作成功",
                    message: "登录成功",
                    style: .success,
                    duration: AppToast.defaultDuration
                )
            )

            ToastView(
                toast: AppToast(
                    title: "操作失败",
                    message: "请求超时",
                    style: .error,
                    duration: AppToast.defaultDuration
                )
            )
        }
    }
}
