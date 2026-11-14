# 平仓后保护单及时清理 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 交易所确认平仓后，快速对账及时关闭本地生命周期并清理所属止损／止盈。

**Architecture:** 复用完整成交锚点与原子关闭、通知、按订单隔离的清理链路；保护和策略入口均检查空仓。空仓查证与有仓兜底各限频 30 秒，空快照本身不能关闭订单。

**Tech Stack:** Python / Django、Decimal、共享缓存、隔离 SQLite 与交易所替身。

---

### Task 1: 复现与边界

- 新建 `server/trading/test_closed_cleanup.py`，通过真实保护／策略服务入口复现空仓被跳过。
- 覆盖已有有仓限频、空仓／反向新仓、完整／不完整成交证据、重复事件限频。
- 运行 `DEBUG=true DB_ENGINE=sqlite3 server/.venv/bin/python server/manage.py test trading.test_closed_cleanup --noinput`，先确认失败。

### Task 2: 最小修复

- 修改 `server/trading/services.py`：空仓不再绕过完整成交核对，使用独立 30 秒限频。
- 证据不足继续保留本地订单与保护；策略入口不再处理已空仓订单。
- 复用既有清理函数，只撤所属订单 ID／客户端前缀，保留同币种新生命周期保护。
- 重跑定向测试及 `trading positions mobile` 回归。

### Task 3: 交付

- 更新 `docs/trading-safety.md`、`docs/development.md`、`docs/changes.md` 的事实、验证与未部署边界。
- 独立只读审查、`git diff --check`、检查未追踪文件；按已有授权提交并推送。
- 不操作真实交易，不部署；线上事件只读取证，残留已由原补偿任务清理。

## 执行结果

新增 4 项回归先失败、修复后通过；完整 `trading positions mobile` 776 项通过，0 失败。独立只读审查无阻塞问题；文档已同步。本轮仅源码交付，未部署或执行真实交易所写操作。

后续用户明确要求部署：`f542783` 已于北京时间 18:16:17 完整发布至 47.80.22.243（首尔服务器）；新镜像隔离 MySQL／Redis 101 项通过，六服务健康、完整运行文件哈希与公网 health 通过。已保存一致性备份，无数据库迁移或清理；客户端打包与安装保持独立交付边界。
