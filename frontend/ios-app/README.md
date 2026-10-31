# TradeTool iOS

SwiftUI starter project for the Trade Tool mobile client.

## Open

Open `TradeTool.xcodeproj` in Xcode, select an iPhone simulator, and run one of
the shared schemes.

## API environments

The app reads `API_BASE_URL` from `Info.plist`, where Xcode expands the value
from `Config/*.xcconfig`, so switching does not require editing Swift code.

| Scheme | Build configuration | API base URL | Use case |
| --- | --- | --- | --- |
| `TradeTool Dev A` | `Debug` | `http://192.168.1.110:8686` | Development network A |
| `TradeTool Dev B` | `Debug-Dev-B` | `http://192.168.31.99:8686` | Development network B |
| `TradeTool Seoul` | `Debug-Seoul` | `https://47.80.22.243` | Seoul server testing from mainland China |
| `TradeTool` | `Debug` for Run, `Release` for Archive | Depends on action | Default run and production archive |
| `TradeTool Release` | `Release` for every action | `https://binance.oovso.com:8443` | Production run, profile, and archive |

If your backend server's LAN address changes, update only the matching
`Config/Debug-Dev-*.xcconfig`. Before release, verify
`Config/Release.xcconfig` still points to the intended production HTTPS API
origin.
For the Seoul deployment, select **TradeTool Seoul** and run on an iPhone.
The server uses an independent test database. Initial login details are in the
local, Git-ignored `../../ops/.env.seoul-test` file; deployment and verification
details are in [the Seoul deployment record](../../docs/SEOUL_DEPLOYMENT.md).
In **Settings → 切换服务器**, choose the original or Seoul server, then tap
**切换并重新载入**. The target is checked before saving; failures keep the current
session. A successful switch rebuilds the app session and root view. The login
page also offers this entry. The choice persists across launches and overrides
the scheme default; development builds retain their configured LAN option.
This reload runs inside the app, without terminating the iOS process.

**测试网络响应** measures three anonymous API requests per server and shows the
median. It checks the server's JSON response and treats the expected HTTP 401 as
reachable, without affecting login state. Test both Wi-Fi and cellular from the
phone and open a chart to check live updates. The Mac comparison and repeatable
native benchmark command are in
[the network report](../../docs/SERVER_NETWORK_COMPARISON_2026-10-31.md).

Login sessions are isolated by API origin (scheme, host, and effective port),
so Dev A, Dev B, and Release never reuse one another's access token. The first
launch after upgrading from the old shared-Keychain build clears that legacy
session and may require one login for each environment; later scheme switches
restore the matching environment's session.
The app keeps a narrow ATS local-network exception in
`TradeTool/Resources/Info.plist` so development can call LAN IPs over HTTP
without enabling arbitrary remote HTTP loads.
Physical-device development also needs the backend port reachable from the
phone. When using local Docker Compose, keep `APP_BIND_HOST=0.0.0.0` in `.env`.
When running from IntelliJ, make sure macOS firewall allows Java on port `8686`.

Before installing on a physical device:

1. Open the `TradeTool` target.
2. Choose your Apple Developer team under **Signing & Capabilities**.
3. Change the bundle identifier if `com.oovso.tradetool` is unavailable.

## Requirements

- Xcode 15 or newer
- iOS 17 or newer
- SwiftUI
- Metal shader toolchain (install the Xcode component if Xcode prompts for it)

## Structure

```text
TradeTool/
├── App/                 App entry point and root navigation
├── Core/
│   ├── Auth/            Login state and Keychain session storage
│   ├── Design/          Binance-inspired visual tokens and components
│   ├── Models/          Shared domain models
│   ├── Networking/      API client foundation
│   └── Presentation/    Reusable app-level toast presentation
├── Features/
│   ├── Auth/            Login screen
│   ├── Chart/           K-line chart and indicator controls
│   ├── ChartEngine/     Native K-line ingress, scene, Metal renderer and host
│   ├── Dashboard/       Market overview
│   ├── Signals/         Strategy signal list
│   └── Settings/        App settings
└── Resources/           Asset catalogs
```

The backend exposes Sa-Token authentication, market ticker snapshots, popular
market pagination, contract search, and realtime market/signal APIs through
`APIClient.swift` and `RealtimeClient.swift`.

The settings page now uses the Java trading APIs described in
`../../docs/TRADING_BACKEND_DESIGN.md`. Binance credential verification,
encrypted storage, balances, positions, and risk-policy persistence are
server-owned. The iOS app retains only the Trade Tool login token, contains no
Binance signer or private endpoint, and removes legacy Binance credential
Keychain entries on launch. The settings UI includes server-owned 1–5 level
exit strategies and the calibrated 1%–25% loss-limit sheet; higher absolute
loss limits are delayed for two hours by Java while lower values apply
immediately. Phase 1 remains read-only with execution hard disabled; settings
do not yet represent continuous protection of real positions.

The chart area now uses the first-party Metal renderer. The original
dependency-free SwiftUI `Canvas` remains only as a no-data or scene-build
fallback, so the long-page layout never becomes blank while a snapshot is
loading. No third-party chart license or package is required.

The first implementation slice of the native chart engine is tracked in
[`docs/KLINE_CHART_ARCHITECTURE.md`](docs/KLINE_CHART_ARCHITECTURE.md).
Same-device Binance/Trade Tool capture, gesture evidence, and pixel-diff rules
are documented in
[`docs/KLINE_CHART_CALIBRATION.md`](docs/KLINE_CHART_CALIBRATION.md). The
repeatable USB/XCUITest device-control and single-indicator capture playbook is
documented in
[`docs/BINANCE_XCUITEST_REAL_DEVICE_CONTROL.md`](docs/BINANCE_XCUITEST_REAL_DEVICE_CONTROL.md).
The dedicated `TradeTool Chart Calibration` scheme always builds `Debug-Dev-B`;
its Trade Tool cases relaunch the candidate so an already-running stale binary
cannot be measured, while Binance cases only activate the user-prepared public
detail page. At the latest-side pan limit the viewport keeps exactly the last
five candles visible; it does not reserve a five-slot blank margin. All
raw screenshots, recordings, result bundles, and traces remain local and are
never committed. `scripts/chart_video_frame.swift` can extract a review PNG
from an XCTest MP4, but that decoded frame remains lossy video evidence and is
not treated as an original screenshot or a pixel golden. For intervals above
the native `1m` feed, the detail page also subscribes to `1m` and merges its
latest price into the selected interval's provisional candle. Every interval
publishes chart frames at most once per 250ms; ticker updates retain the 24h
statistics and provide a fallback price source. A REST snapshot reconciles
every interval every 15 seconds, including `1h`.
`TradeToolTests` covers the realtime ingress barriers, structural sharing,
relative-coordinate precision, committed/provisional indicator behavior,
render-state coalescing, deterministic Metal golden images, resource-ring
safety, production scene building, the indicator registry, ta4j-compatible
SuperTrend/MACD/VOL rules, multi-panel layout, and renderer failure policy. MetricKit
receives privacy-safe aggregate performance and
diagnostic counts; chart signposts contain revisions only, never symbols,
prices, accounts, or trade payloads.

The production chart data path now drives the visible Metal chart while the
former static chart remains as the no-data/build-failure fallback.
`MarketChartViewModel` loads a validated 1,500-bar REST snapshot and
feeds bounded WebSocket events into `ChartDataPipeline`, which owns stream
epochs, sequence-gap recovery, `CandleStore`, and the registered indicator
engine. Near the oldest loaded edge, the app requests strictly older pages
through `beforeOpenTime`, prepends them without moving the visible time window,
and keeps at most 10,000 candles in memory. EMA21/55/144, SuperTrend(10,6),
MACD(12,26,9), VOL/MA5/MA10, Wilder RSI(14), KDJ(9,3,3), OBV, WR(14),
StochRSI(14,14,3,3), and ATR(14) use
committed/provisional calculators and publish structurally shared snapshots at
most every 250ms. The detail-page indicator bar now drives the production
pipeline directly from the fixed bottom strip: overlays toggle independently,
while every subchart can be shown as an independent panel. O.I.,
top-account/top-position/global long-short
ratios, taker buy/sell volume, and basis panels consume the optional
`tradingData` attached to the newest REST candle; price-only realtime updates
preserve it until the next 15-second reconciliation. The data-driven catalog,
versioned selection, and parameters are stored locally; changing them rebuilds
indicators atomically from cached candles without clearing the visible frame or
losing pending realtime updates. The indicator-settings control edits and
persists every configurable overlay and technical subchart
parameters through a validated draft from the bottom menu; applying a new preset
uses the same atomic configuration-revision path and updates instance identities
and legends.
The chart fills the space between the compact contract header and the fixed
bottom controls. Header tabs, the large market summary, and the duplicate interval
toolbar have been removed. The first screen shows the price chart and only the
first enabled indicator panel, with the 24pt time axis directly below the price
chart. Remaining panels are kept below the fold, not disabled. Indicator panels
remain 72pt high with a 16pt legend footer; live and crosshair values use the same
footer. Grid and crosshair lines stop at each plot boundary. The header bell is
removed and the favorite star occupies its rightmost position.
Panels follow activation order. Closing and reopening a panel appends it to the
end; symbol/interval changes and normal app relaunches preserve the saved order.
Calibration presets are applied once at launch, not every time a chart is opened.
Extra price-plot height expands the price domain relative to the
original 268pt plot, preserving default candle body/wick proportions and horizontal
width while still allowing manual price-axis zoom.
The scrolling chart detail ends at the chart time axis. The duplicate indicator
row, performance summary, order book, depth chart, and recent-trades preview have
been removed along with their depth polling and backend depth endpoint. The fixed
bottom indicator strip, symbol/interval wheels, and trading menu remain available.
`ChartSceneBuilder` consumes generic indicator series rather than hard-coded
fields. A reusable panel layout gives the price panel and indicator panels a
shared time axis with independent Y domains, and compiles lines, histograms,
legends, candles, grid, axes, and the latest-price marker into layered
`RenderState` snapshots. Same-bar updates reuse the immutable static scene and
only replace the lightweight live-tail batch.

The production interaction path is also connected. A UIKit host
arbitrates one-finger horizontal chart pan against the detail page's vertical
scroll, preserves the iOS left-edge navigation gesture, and handles anchored
two-finger timeline zoom. The viewport keeps fractional candle offsets,
preserves a historical window when new bars append, hides the live tail when it
is outside that window. Returning to latest is gesture-driven; there is no
floating quick-reset control. The scene now keeps 48 timeline
slots of guard-band geometry on each side of the visible window. Pan and pinch
samples update only a lightweight Metal interaction transform while they remain
inside that band; crossing it keeps accepting live gesture samples while a
latest-only render queue rebases the stable scene. Price-scale changes use the
same continuous display-link path and coalesce obsolete scene builds instead of
waiting for the gesture to end. Grid, axes, legends, and the latest-price marker
stay in fixed screen coordinates; the latest-price dashed line keeps its axis
endpoint fixed while its candle endpoint follows pan and pinch frames. Timeline
geometry and horizontal grid lines
use the full chart width beneath the transparent right-hand scale instead of
being clipped at its left edge. Grid bars are packed in a dedicated background
batch so MACD, volume, and other panel geometry always renders above them. One
shared display link now continues a released pan with
bounded deceleration, applies capped rubber-band resistance at the latest/oldest
edge, and settles it with a critically damped spring. Guard-band rebases pause
and resume the same motion instead of terminating a long fling. The production
long-press crosshair now interrupts motion, snaps in O(1) through the active
interaction transform, preserves its selected `openTime` across rebases, and
links OHLC, change, volume, and enabled-indicator values through a bounded
fixed-coordinate overlay. Historical selections stay immutable while the live
candle remains provisional. Final same-device Binance gesture/pixel trace
calibration is the next Stage 2 work; current motion and crosshair thresholds
remain centralized provisional behavior tokens rather than claimed final
matches.

The drawing-tool foundation is separate from both indicators and the renderer.
Versioned annotations store `openTime + Decimal price` anchors and are
validated through a tool registry. Horizontal/vertical lines, trend lines,
rays, and range measurement share projection, hit testing, scene compilation,
selection/editing, lock/hide, bounded undo/redo, and atomic per-symbol JSON
persistence. This is an engine foundation: the detail-page tool palette,
control-point gestures, and property editor are the next UI slice.

The Debug build also provides a launch-argument-gated
`--chart-stress` foreground harness for physical `MTKView` validation. It is
not reachable during a normal app launch and is compiled out of Release
builds. The default `quick` scenario keeps the short 4Hz/20Hz and lifecycle
checks. Long-running scenarios are configured without rebuilding:

```text
CHART_STRESS_SCENARIO=interaction
CHART_STRESS_DURATION_SECONDS=1800

CHART_STRESS_SCENARIO=soak
CHART_STRESS_DURATION_SECONDS=7200
CHART_STRESS_BURST_ROUNDS=10

CHART_STRESS_SCENARIO=pipeline
CHART_STRESS_DURATION_SECONDS=60
CHART_STRESS_BURST_ROUNDS=10

CHART_STRESS_SCENARIO=lifecycle
CHART_STRESS_LIFECYCLE_CYCLES=500

CHART_STRESS_SCENARIO=app-lifecycle
CHART_STRESS_APP_LIFECYCLE_CYCLES=20
CHART_STRESS_EXTERNAL_LIFECYCLE_CYCLES=1

# Unattended device runs: flush the terminal result and exit 0/1.
CHART_STRESS_EXIT_AFTER_RESULT=1
```

The same values can be passed as `--chart-stress-scenario`,
`--chart-stress-duration`, `--chart-stress-burst-rounds`, and
`--chart-stress-lifecycle-cycles`,
`--chart-stress-app-lifecycle-cycles`, and
`--chart-stress-external-lifecycle-cycles` launch arguments.
`--chart-stress-exit-after-result` enables the same unattended exit behavior.
The exit switch is opt-in, Debug-only, and flushes `CHART_STRESS_RESULT`
before returning process status `0` for PASS or `1` for FAIL.
The Debug harness also disables the iOS idle timer only while its view is
visible so unattended interaction/soak runs do not auto-lock the device.
An external app-lifecycle cycle waits for the app to be sent to the real iOS
background
and activated again.
Terminal and progress lines are also atomically overwritten in the Debug app
container at `Library/Caches/ChartStress/latest-result.txt` and
`latest-progress.txt`. These bounded files contain aggregate diagnostics only
and allow a completed device run to be recovered if the console detaches.
The harness prints bounded whole-run latency histograms, presentation counts,
GPU health, the latest real command-buffer failure status/domain/code when one
exists, and resident-memory start/end/peak delta. Current device evidence and
remaining soak work are recorded in
[`docs/KLINE_CHART_STAGE_0_5_TEST_REPORT.md`](docs/KLINE_CHART_STAGE_0_5_TEST_REPORT.md).
The `pipeline` scenario additionally drives the real
`KlineIngressState -> CandleStore -> provisional EMA21/55/144 -> RenderState`
path before Metal. It combines normal 4Hz input with bounded 20Hz bursts and
deterministic duplicate, gap, invalid-candle, out-of-order, and upstream-drop
recovery checks.

Authentication and the visual system are documented in
[iOS authentication and design](docs/DESIGN_AND_AUTH.md).

## Authentication

- The root view switches between login and authenticated content.
- `POST /api/auth/login` creates a session.
- Access tokens and user metadata are stored in iOS Keychain.
- `POST /api/auth/logout` is attempted after local session removal.
- The global bearer interceptor attaches the access token to API requests.
- A `401` response clears the local session and returns to the login screen.

The Java backend implements these endpoints with Sa-Token. Configure
`Config/Release.xcconfig` to the HTTPS API origin before archiving the app.

## Visual style

The app uses a Binance-inspired dark trading interface: charcoal surfaces,
yellow primary actions, compact market rows, monospaced prices, and consistent
green/red market semantics. It does not include or copy Binance trademarks or
proprietary visual assets.

When rebuilding screens from screenshots or Figma references, use those
references for structure and hierarchy only. Typography, spacing, button sizes,
navigation, and toast behavior must follow
[`docs/DESIGN_AND_AUTH.md`](docs/DESIGN_AND_AUTH.md). Do not reverse engineer,
decompile, extract, or copy third-party app source code or private assets.
The app centralizes text and numeric font mapping in `BinanceTheme.Typography`.

## Networking

The project uses native `URLSession` with Swift concurrency and does not
require a third-party networking or toast dependency.

- `APIRequest` describes method, query, JSON body, timeout, and response mode.
- `APIInterceptor` adds shared headers, bearer tokens, and HTTP validation.
- `APIEnvelope` supports the common `code/message/data` response contract.
- `APIError` maps HTTP, business, decoding, timeout, and connectivity failures.
- `AppToastCenter` displays intercepted failures as a centered, non-blocking
  toast and can also be called directly by any feature.

Requests display errors by default. Pass `showsErrorToast: false` when a
specific screen needs to handle an error locally.

Any SwiftUI view can also display a toast directly:

```swift
@EnvironmentObject private var toastCenter: AppToastCenter

toastCenter.success("保存完成")
toastCenter.warning("部分数据尚未同步")
toastCenter.error("提交失败，请稍后重试")
toastCenter.present("自定义提示", title: "提示", style: .info)
```
