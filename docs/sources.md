# 原项目来源与历史查询

2026-10-31 按用户要求，当前目录仅保留整合实现，删除原项目的参考代码、旧 Web、旧部署和历史文档副本。原始目录继续只读，后续查历史直接使用以下路径。

| 来源 | 本地原始目录 | 查询入口 |
| --- | --- | --- |
| USDT Python / Web | `/Users/apple/work/TradeTools-Binance`，排除其中本整合子目录 | `server/`、`tools/`、`docs/`、`deploy/` |
| USDC Java / iOS | `/Users/apple/work/tradetools-usdc` | `backend/app-service/`、`frontend/ios-app/`、`docs/` |
| 当前整合版 | `/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS` | `server/`、`frontend/ios-app/`、`deploy/integrated/` |

## 清理边界

整合版继续使用的 Python 业务模块、数据库迁移、原生行情 / Metal 图表、业务页面、共享模型及测试均保留。文件名中的 USDT 或测试数据中的 USDC 表示资产或协议来源，不能据此删除仍被使用的实现。

已移除的参考副本包括 Java 后端、React Web、旧 Compose / Jenkins / Nginx / 运维、网络对比材料、历史方案，以及未接入整合导航的旧原生页面和旧 LAN Scheme。原生图表的当前维护说明保留在 [行情文档](market-data.md)，原设计历史从 USDC 来源目录查看。

## Git 查询

清理前完整快照为独立 GitHub 仓库的 `7e3d166`。普通 clone 后可以只读查看某个已删除文件：

```bash
git show 7e3d166:backend/app-service/pom.xml
git show 7e3d166:tools/package.json
```

本机当前目录位于父 Gitee 仓库中，需要使用 [运维文档](operations.md#github-源码交付) 的独立 Git 参数查询该基线。历史文件仅作为参考，不整批恢复覆盖当前实现。

2026-11-05 的前端与推送对照使用整合版 `dd4e5db` 和 USDC `104d7d7fc44d244087fa06841659246965b3914b`；所读 USDC 图表／网络／Java 行情与推送／主配置路径相对该 HEAD 无未提交改动，目录内其他 Scheme 和网络研究材料保留原状。对照及当前差异统一维护在 [行情主文档](market-data.md#与-usdc-的前端和数据推送对照2026-11-05)，不恢复旧源码副本。

2026-11-06 再次对照以整合版 `7e8a4ab` 和同一 USDC `104d7d7` 为基线，所选当前 16 个、来源 12 个文件均与各自 HEAD 一致。共享分发后的剩余差异与候选方向见 [当前对照](market-data.md#与-usdc-再次对照与后续方向2026-11-06)，哈希清单与验证边界见 [开发记录](development.md#usdc-再次源码对照2026-11-06)。
