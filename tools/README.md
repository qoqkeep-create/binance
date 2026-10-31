# TradeTools 前端

React / TypeScript / Vite 应用，目录名 `tools` 是历史命名。完整规范以 [开发与验证](../docs/development.md) 为准，项目总览见 [根 README](../README.md)。

## 快速开始

使用 Node.js 20，在本目录执行；后端开发服务先运行于 8000：

```bash
npm ci
npm run dev -- --host 127.0.0.1
```

默认访问 [本地前端](http://127.0.0.1:5173)，端口占用时以启动输出为准。当前工作区已由并行任务加入 `/api` -> `/v1` 代理及 `DEV_API_PROXY_TARGET`，默认本机 8000；尚未作为本轮发布或验收。旧 `8de868a` 版本启动需显式 `VITE_API_BASE_URL=/v1`，完整状态见 [开发文档](../docs/development.md)。依赖以 [package-lock.json](package-lock.json) 锁定，不再使用旧 pnpm 安装流程。

```bash
npm test
npm run build
npm run lint
```

## 维护入口

- [App.tsx](src/app/App.tsx)：路由、页面加载；页面位于 `src/pages`。
- [API client](src/shared/lib/api/client.ts)：认证和统一请求；禁止将密钥放入 `VITE_*`。
- [K 线说明](../docs/market-data.md)：缓存、WS、兜底和图表测试。
- [转账历史](../docs/capital-and-transfers.md)：首次读库与显式同步。
- [信号与通知](../docs/signals-and-notifications.md)：内外部来源和显示口径。

提交前按 [项目协作规则](../AGENTS.md) 评估是否同步更新文档。
