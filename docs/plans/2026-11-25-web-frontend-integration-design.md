# Web 前端整合设计

日期：2026-11-25

## 目标

把 `/Users/apple/work/trade-web` 复制到当前整合仓库，作为与 iOS 并列的 React/Vite Web 前端；保留现有 Web 页面、样式和分析逻辑的展示形态，将行情、K 线、认证和偏好存储接入当前 Django 整合后端。

## 方案

Web 源码放在 `frontend/trade-web/`，不再运行来源项目的 Flask 服务。Django 继续作为唯一业务后端：现有 `mobile` 认证适配复用 iOS 用户体系，`market_stream` 提供 ticker、K 线快照和 Redis/数据库行情管理，新增 `web` app 仅保存 Web 页面偏好并使用版本号防止并发覆盖。原 Flask SQLite 账户、会话和数据库不迁移，避免产生第二套账号和交易状态。

行情请求统一使用同源 `/api/market/*`。K 线数据从 `market_stream.service.load_history` 的 `items` 转换为 Web 的 `Candle`；ticker 使用 Django 的 `lastPrice`、`priceChangePercent24h`、`quoteVolume24h` 字段。实时数据使用 `/ws/v1` 的 `market.ticker`/`market.kline` 订阅，浏览器通过 WebSocket subprotocol 发送短期 JWT，避免继续直连 Binance。连接中断时保留 REST 快照并自动重连。

认证保留现有页面：表单仍由 Web 原组件呈现，客户端保存短期 access token，refresh 通过 Django HttpOnly cookie；请求 401 时调用 `/api/auth/refresh` 后重试一次。Web 偏好接口为 `/api/web/settings`，协议保持来源 Flask 的 `settings/version/updatedAt` 和乐观版本冲突语义。

## 验证边界

验证包括 Web 的 `npm run test`、`npm run build`，Django `check`、`makemigrations --check`、Web settings 测试和现有行情/认证定向测试。只验证本地数据链路和替身，不进行真实开平仓、资金划转、保护单操作或生产部署；真实服务器状态仍按独立运维文档记录。
