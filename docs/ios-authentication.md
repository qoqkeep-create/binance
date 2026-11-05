# iOS 品牌与认证界面

## 当前实现

手机桌面名称为 **Binance Tools**，Debug、Debug-Seoul、Release 均一致；Bundle ID 仍为 `com.waibao2025.trade.integrated`，更新安装继续使用同一个应用身份。桌面名称由 Xcode 工程的 `INFOPLIST_KEY_CFBundleDisplayName` 指定，不等同于 App Store Connect 中的商店名称。

App 图标采用橙色到珊瑚红的渐变底色与象牙白折带 B 标记。`Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` 是 1024 × 1024、无透明通道的发布图标；`BrandMark.imageset` 保存同源的 64 / 128 / 192 像素标记，供 App 内品牌组件使用。桌面圆角由系统裁切，App 内标记由 `BinanceLogoMark` 使用连续圆角裁切。

系统启动页使用 `Info.plist` 的 `UILaunchStoryboardName = BrandLaunchScreen`，固定 RGB 纯白，居中图标从 64 pt 放大 50% 至 96 pt；会话恢复页 `AppLaunchView` 同样为固定白底、96 pt 图标，深色模式也保持白底。两阶段都相对完整窗口居中，整个 `AppLaunchView` 容器忽略安全区，并共用专用 `LaunchBrandMark.imageset`。启动 storyboard 不应用运行时圆角属性，因此该图集在 96 / 192 / 288 像素资源中预渲染 SwiftUI 连续圆角（半径为边长的 22%），四角透明。资源由 [生成脚本](../frontend/ios-app/scripts/render_launch_mark.swift) 从发布图标生成，命令见 [开发文档](development.md)。启动背景独立于业务主题，不能只修改登录页背景。

2026-11-05 定位到启动交接轻微位移：旧 SwiftUI 实现只有背景忽略安全区，图标按安全区居中，而 storyboard 按整个窗口居中；上下安全区不等时，两者相差 `(top - bottom) / 2`，59／34 pt 场景像素复现下移约 13 pt。修复同时统一上述布局基准和图标资源，避免运行时再次缩放裁切造成外观跳变。回归与实机待验边界见 [开发验证](development.md#启动图标交接2026-11-05本地)。

同一个本地构建号反复更换启动资源会复用旧资源缓存：此前替换图集并重装后仍见旧黑底图标，更换图集名称后曾只显示白底；重启模拟器也未解除。当时以命令行临时 `CURRENT_PROJECT_VERSION=4` 重新安装后，冷启动显示白底、当时的 64 pt 新图标；当前尺寸已调整为上述 96 pt。未改工程中的发布版本号或 Cloud 自动递增规则。后续启动页验收需使用新构建号，不能把相同构建号的旧缓存当成包内资源；手机需安装此次新的 TestFlight 构建后再核对。

登录、注册布局依据 [USDC 原始工程](sources.md) 的 `Features/Auth/LoginView.swift`，使用现有 `BinanceTheme`：左右 24 pt、品牌标记 42 pt、品牌区下方间距 48 pt、标题 32 pt、字段标签与输入间距 9 pt、字段间距 18 pt、输入和主按钮圆角 10 pt，保留来源黄色主按钮与浅深色。新增品牌色用于图标，其他业务页面沿用原主题。

登录页只保留居中的“注册账号”入口，移除其前方“没有账号”文案。全局浮字提示最大宽度从 240 pt 调为 180 pt，纯文字纵向内边距从 11 pt 调为 14 pt，长文字自动折成最多两行。

登录是根页面；注册、找回密码、重置密码使用共享 `WebSheet`，面板高为可用容器的 96%，保留拖动条、24 pt 顶角与关闭按钮，支持头部下拉关闭。协议和隐私页改用与交易对、归集、杠杆一致的 80% `WebSheet`；贴底、安全区及键盘规则见 [原生页面](ios-web-parity.md#自选与交易对底部列表2026-11-01)；在注册面板内阅读后回到原表单。大面板以 0.18 秒从底部展开，0.14 秒关闭；启用系统“减弱动态效果”时改为淡入淡出，公共动画规则见 [原生页面](ios-web-parity.md)。表单过高或键盘弹出时可以滚动。提交期间禁止重复提交与手势关闭，显式关闭会取消当前页面请求；切到其他表单清空密码，新开注册表单不沿用上一次输入的密码。

协议内容复用 `USDTLegalView`；标题和 X 关闭位于正文同一表面，已移除独立标题条与“完成”。每种认证表单使用独立的控件标识，避免注册 sheet 与背后的登录页混淆；共用面板及验证见 [原生页面](ios-web-parity.md#自选与交易对底部列表2026-11-01)。

邮箱与密码通过 `AuthTextInput` 使用同一套 UIKit 编辑与焦点桥接；密码保持同一个 UITextField 与右侧显隐按钮，切换时修改 secure entry 并保留文本和选区。SwiftUI 负责来源布局，原生事件确认当前焦点；避免在显隐切换时替换编辑器或混用两套焦点系统。

## 对应接口

| 功能 | 整合后端接口 | 行为 |
| --- | --- | --- |
| 登录 | `POST /api/auth/login` | `account` 为邮箱，提交 `password` 和 `agreed`，沿用 AuthStore / Keychain 与刷新机制 |
| 注册状态 | `GET /v1/auth/admin-settings` | 读取 `open_registration`；关闭、加载中或获取失败时禁止注册，失败可重试 |
| 注册 | `POST /api/auth/register` | 沿用邮箱、密码、确认密码和同意协议字段；后端仍执行开关、限流和密码校验 |
| 找回密码 | `POST /v1/auth/password-reset/request` | 提交 `email`，统一提示避免泄露账号是否存在；禁用重复请求 |
| 确认重置 | `POST /v1/auth/password-reset/confirm` | 解析已交给 App 的 `reset_uid` / `reset_token`，提交 `uid`、`token`、`new_password`、`confirm_password` |
| 用户协议 / 隐私政策 | 本地原生内容 | 不依赖新接口，品牌名称同步更新 |

仅呈现上述已有能力，不增加第三方登录、短信或验证码入口。UI 使用邮箱字段以符合当前后端的 EmailField，未沿用来源“账号或邮箱”中后端不支持的任意用户名含义。认证沿用原有服务模块，未修改 Python 资金、交易与订单业务。

SMTP 实际投递与邮件 HTTPS 自动唤起不由界面改造自动完成；Universal Links 仍待配置和验收。外部链接需要先由 iOS 路由交给 App，才能打开重置 sheet；限制见 [已知事项](known-issues.md) 和 [TestFlight](testflight.md)。

2026-11-01 已按用户授权在 47.80.22.243（首尔服务器）将持久化的 `SystemSetting.open_registration` 从关闭改为开启，公网匿名状态接口已核对为 true。开关保存在数据库，不通过客户端写死或修改默认策略；管理员仍可在设置中关闭。操作及最后核对时间见 [运维](operations.md#注册开关) 和 [变更与验收](changes.md)。

## 验证与维护

`WebParityUITests` 的认证流程使用 DEBUG 无网络页面替身。`--fixture-registration-open` / `--fixture-registration-unavailable` 分别模拟开放和状态读取失败，默认模拟关闭；这些标记不进入 Release。测试使用保留的邮箱 / 密码验证与无效表单，不注册真实账号、不发送真实邮件、不调用交易写接口。界面结果与构建报告记录在 [变更与验收](changes.md)，截图需实际打开检查。

自动化注册输入先切换为明文并核对完整文本，避开系统复杂密码建议打断快速输入的情况，再切回密文检查不一致提示。生产继续保留系统密码自动填充，未禁用后端复杂度校验；该自动化绕过不代表系统密码建议在真机上已专项验收。

图标由内置 imagegen 生成，交付资源保存在工程内。原图仅做发布尺寸缩放；最终生成提示词如下，后续换图时同步更新本节与资源，不依赖个人生成缓存目录。

```text
Use case: logo-brand. Asset type: final iOS app icon for Binance Tools, one single square icon, 1024 by 1024. Create a premium, exceptionally minimal financial tools icon. Full bleed smooth warm gradient background flowing from luminous tangerine orange at upper left through vivid vermilion to deep coral red at lower right. Center a single bold ivory-white abstract geometric mark: an elegant ascending folded ribbon forming a subtle capital B, with two precise negative-space cuts. Flat crisp vector-like silhouette, balanced proportions, large readable at tiny app-icon size, centered with generous optical padding. Understated, refined, precise, modern. Gradient is soft and rich with a restrained diffuse glow; foreground mark has no bulky extrusion. Fill the entire square edge to edge, no rounded outer corners, no frame, no device mockup, no surrounding canvas, no lettering, no words, no numbers, no watermarks.
```
