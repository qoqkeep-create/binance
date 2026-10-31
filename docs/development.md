# 开发与验证

当前工程入口见 [README](../README.md)，配置见 [配置字典](configuration.md)。以下命令在本整合目录执行。

## Python

使用 Python 3.11，按锁定依赖创建本地环境：

```bash
python3.11 -m venv server/.venv
server/.venv/bin/python -m pip install -r server/requirements.txt
cp server/.env.example server/.env
```

开发配置使用 SQLite、独立 Redis 和无交易绑定账号。HTTP / WSS 由 ASGI 运行：

```bash
cd server
.venv/bin/python manage.py migrate
.venv/bin/python -m uvicorn riskon.asgi:application --host 127.0.0.1 --port 8787
```

行情、命令和调度分别运行 `manage.py market_stream`、`mobile_worker`、`run_scheduler`；测试期间不启动实际账户维护进程。只有需要完整本地链路时，才配置独立 Redis 并分别启动。

不读取本地真实 `.env` 的基础验证：

```bash
cd server
export PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false
.venv/bin/python manage.py check
.venv/bin/python manage.py makemigrations --check --dry-run
.venv/bin/python manage.py test
```

SQLite / LocMem 不能替代 MySQL 事务、唯一约束及 Redis 跨进程验收。相关测试位于 `server/integration_tests/`，使用测试专用数据库和 Redis；不得指向生产环境。普通回归使用交易所替身，不实际开平仓、划转或撤保护单。

## iOS

打开 `frontend/ios-app/TradeTool.xcodeproj`。保留的 Scheme 为 `TradeTool`、`TradeTool Seoul`、`TradeTool Release`、`TradeTool Chart Calibration`；Debug / Debug-Seoul / Release 默认均指向整合服务器。本地开发入口可在 App 服务器设置中选择，手机的 `127.0.0.1` 指手机自身。

```bash
xcodebuild -project frontend/ios-app/TradeTool.xcodeproj -scheme TradeTool   -configuration Debug-Seoul -destination 'platform=iOS Simulator,name=iPhone 18 Pro'   -derivedDataPath .integration-runtime/DerivedData   CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

模拟器 Keychain 测试保留临时签名与 simulated entitlements。发布构建及 TestFlight 使用有效 Apple 团队签名，见 [手机发布指南](testflight.md)。

Xcode Cloud 的 Test action 选 `TradeTool`（包含单测），Archive action 选 `TradeTool Release`（Release）；后者的 TestAction 无测试列表。工程旁的 `ci_scripts/ci_pre_xcodebuild.sh` 自动检查 Metal Toolchain 并按需下载，可用以下替身测试检查安装、已安装、并发导入及持续失败分支，不访问 Apple 或交易所：

```bash
sh frontend/ios-app/ci_scripts/tests/ci_pre_xcodebuild_test.sh "$PWD/frontend/ios-app/ci_scripts/ci_pre_xcodebuild.sh"
```

Cloud 分发使用平台自动递增的构建号，首次在后台核对 Next Build Number；不在脚本里修改版本或提交回 Git。隐私清单已加入主 App 资源。云端签名、上传、Apple 处理和手机安装仍要分别验收，具体工作流设置见 [TestFlight 指南](testflight.md#xcode-cloud自动构建与-testflight-分发)。

`IntegratedNativeUITests` 为 opt-in 的完整登录 / 页面检查，需要本地无绑定 QA 账户环境变量；缺少时跳过。其他 UI 校准脚本和 Debug harness 用于行情 / Metal，不把离屏测试当作真机帧率或长稳结果。

## 回归范围

- 行情与命令：`market_stream.tests`、`mobile.tests`，覆盖聚合、缺口、分页、鉴权、模式及绑定代际、幂等与恢复。
- 交易与资金：既有 `trading`、`positions`、`accounts`、`api_bindings` 测试覆盖精度、保护、未知结果及账户隔离。
- iOS：图表、Keychain、服务器切换和业务会话测试；设备运行单独记录。
- 提交前检查文档链接、敏感信息、`git diff --check` 和未追踪文件。实际结果写入 [变更记录](changes.md)。
