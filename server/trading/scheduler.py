"""
T027: 定时任务调度器
同步限价委托单状态
"""
import logging
from datetime import datetime, timedelta
from functools import wraps

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.executors.pool import ThreadPoolExecutor
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from django.conf import settings
from django.db import close_old_connections

from common.errors import safe_error_summary

logger = logging.getLogger(__name__)

_scheduler = None


def _with_database_connections(job):
    """Give reused scheduler threads the connection cleanup HTTP requests get."""
    @wraps(job)
    def run(*args, **kwargs):
        close_old_connections()
        try:
            return job(*args, **kwargs)
        finally:
            close_old_connections()
    return run


def _scheduler_heartbeat_job():
    """Refresh the scheduler readiness lease without touching business data."""
    try:
        from common.health import touch_scheduler_heartbeat

        touch_scheduler_heartbeat()
    except Exception as e:
        logger.error("定时任务调度器心跳失败: %s", safe_error_summary(e))


@_with_database_connections
def _sync_limit_orders_job(trading_mode="ordinary"):
    """定时同步限价委托单状态"""
    try:
        from trading.services import sync_all_pending_limit_orders
        sync_all_pending_limit_orders(trading_mode=trading_mode)
    except Exception as e:
        logger.error("定时同步限价委托单失败: %s", safe_error_summary(e))


@_with_database_connections
def _run_strategy_engine_job(trading_mode="ordinary"):
    """定时执行止盈策略引擎"""
    try:
        from trading.services import run_strategy_engine

        run_strategy_engine(trading_mode=trading_mode)
    except Exception as e:
        logger.error("定时执行策略引擎失败: %s", safe_error_summary(e))


@_with_database_connections
def _reconcile_order_protection_job(trading_mode="ordinary"):
    """低频对账修正订单仓位与止损单"""
    try:
        from trading.services import reconcile_open_orders_protection

        reconcile_open_orders_protection(trading_mode=trading_mode)
    except Exception as e:
        logger.error("定时订单保护对账失败: %s", safe_error_summary(e))


@_with_database_connections
def _reconcile_external_positions_job(trading_mode="ordinary"):
    """持续扫描手动仓，恢复强制止损并处理超额亏损。"""
    try:
        from trading.external_positions import reconcile_external_positions

        reconcile_external_positions(trading_mode=trading_mode)
    except Exception as e:
        logger.error("定时手动仓保护失败 mode=%s: %s", trading_mode, safe_error_summary(e))


@_with_database_connections
def _reconcile_stale_open_orders_job():
    """低频修正交易所已无仓位但本地仍未平仓的旧单"""
    try:
        from positions.views import reconcile_stale_open_orders

        reconcile_stale_open_orders()
    except Exception as e:
        logger.error("定时修正陈旧未平仓订单失败: %s", safe_error_summary(e))


@_with_database_connections
def _reconcile_position_settlement_job():
    """低频补偿已平仓订单的真实结算结果"""
    try:
        from positions.views import reconcile_pending_order_settlements

        reconcile_pending_order_settlements()
    except Exception as e:
        logger.error("定时持仓结算补偿失败: %s", safe_error_summary(e))


@_with_database_connections
def _sync_entry_fees_job():
    """异步补齐持仓开仓真实手续费"""
    try:
        from positions.views import sync_pending_entry_fees

        synced = sync_pending_entry_fees()
        if synced:
            logger.info("开仓手续费同步完成: %s", synced)
    except Exception as e:
        logger.error("定时同步开仓手续费失败: %s", safe_error_summary(e))


@_with_database_connections
def _dispatch_trade_notifications_job():
    """异步发送交易事件通知；两个目标各自保留状态并独立重试。"""
    try:
        from positions.notifications import dispatch_pending_trade_notifications

        sent = dispatch_pending_trade_notifications()
        if sent:
            logger.info("交易通知发送完成: %s", sent)
    except Exception as e:
        logger.error("定时发送交易通知失败: %s", safe_error_summary(e))
    try:
        from positions.external_trade_signals import dispatch_pending_external_trade_signals

        sent = dispatch_pending_external_trade_signals()
        if sent:
            logger.info("外部交易信号发送完成: %s", sent)
    except Exception as e:
        logger.error("定时发送外部交易信号失败: %s", safe_error_summary(e))


@_with_database_connections
def _dispatch_mobile_notifications_job():
    from mobile.push import dispatch_notifications
    from positions.profit_alerts import scan_profit_alerts, dispatch_profit_alerts
    for job in (dispatch_notifications, scan_profit_alerts, dispatch_profit_alerts):
        try:
            job()
        except Exception as exc:
            logger.warning('notification job failed job=%s error_type=%s', job.__name__, type(exc).__name__)


@_with_database_connections
def _dispatch_live_activities_job():
    """Read-only position snapshots; never calls the trading/protection workers."""
    from mobile.live_activities import dispatch_live_activities
    try:
        dispatch_live_activities()
    except Exception as exc:
        logger.warning('live activity job failed error_type=%s', type(exc).__name__)


@_with_database_connections
def _audit_suspicious_closed_orders_job():
    """巡检异常平仓记录（本地已平仓但缺少交易所平仓锚点）"""
    try:
        from positions.views import audit_suspicious_closed_orders

        audit_suspicious_closed_orders()
    except Exception as e:
        logger.error("定时异常平仓巡检失败: %s", safe_error_summary(e))


@_with_database_connections
def _reconcile_closed_order_exchange_artifacts_job():
    """补偿已结束订单残留挂单"""
    try:
        from positions.views import reconcile_closed_order_exchange_artifacts

        reconcile_closed_order_exchange_artifacts()
    except Exception as e:
        logger.error("定时补偿已结束订单残留挂单失败: %s", safe_error_summary(e))


@_with_database_connections
def _trend_signal_scan_job():
    """自有趋势信号扫描（SuperTrend+EMA 状态机，替代原行情扫描与 TradingView 提醒）"""
    try:
        from market_analysis.trend import scan_trend_signals

        result = scan_trend_signals()
        logger.info("趋势信号扫描完成: %s", result)
    except Exception as e:
        logger.error("定时趋势信号扫描失败: %s", safe_error_summary(e))


@_with_database_connections
def _purge_tradingview_messages_job():
    """定期清理超过保留期的 TradingView 信号消息"""
    try:
        from trading.views import purge_expired_tradingview_messages

        purge_expired_tradingview_messages()
    except Exception as e:
        logger.error("定时清理TradingView消息失败: %s", safe_error_summary(e))


@_with_database_connections
def _warm_market_klines_job():
    """后台预热公开 K 线缓存，让用户切换币种/周期时直接命中缓存"""
    try:
        from trading.views import warm_market_kline_caches

        warm_market_kline_caches()
    except Exception as e:
        logger.error("定时预热K线缓存失败: %s", safe_error_summary(e))


@_with_database_connections
def _prewarm_market_snapshots_job():
    """按周期节奏请求公开快照 URL，保持 CDN 副本常热，消除首屏跨境回源"""
    try:
        from trading.snapshot_prewarm import prewarm_public_snapshot_caches

        result = prewarm_public_snapshot_caches()
        if result["checked"]:
            logger.info("公开快照 CDN 预热完成: %s", result)
    except Exception as e:
        logger.error("定时公开快照 CDN 预热失败: %s", safe_error_summary(e))


@_with_database_connections
def _balance_cap_cycle_job():
    """资金提醒：只读检查资金缺口和待归集现货，绝不自动划转。"""
    try:
        from trading.balance_cap import run_capital_reminder_cycle

        run_capital_reminder_cycle()
    except Exception as e:
        logger.error("定时资金提醒检查失败: %s", safe_error_summary(e))


@_with_database_connections
def _sync_transfer_history_job():
    """每日增量同步转账历史，单账户失败由同步服务隔离。"""
    try:
        from accounts.transfer_history import sync_all_transfer_histories

        result = sync_all_transfer_histories()
        logger.info("转账历史增量同步完成: %s", result)
    except Exception as e:
        logger.error("定时同步转账历史失败: %s", safe_error_summary(e))


def start_scheduler():
    """启动定时任务调度器"""
    global _scheduler

    if _scheduler is not None:
        return

    _scheduler = BackgroundScheduler(executors={"default": ThreadPoolExecutor(10), "lead": ThreadPoolExecutor(3)})

    now = datetime.now()

    # Reuse the same execution code, with separate batches and workers so a
    # slow lead portfolio cannot occupy ordinary protection's execution slot.
    # Keep running even when new lead entries are disabled: existing positions
    # still need protection. The external scan must also discover positions that
    # have no local order yet, so it reads all eligible bound accounts.
    for func, job_id, seconds, offset in (
        (_sync_limit_orders_job, "lead_sync_limit_orders", 5, 2),
        (_run_strategy_engine_job, "lead_strategy_engine", 10, 4),
        (_reconcile_order_protection_job, "lead_order_protection", 10, 6),
        (_reconcile_external_positions_job, "lead_external_positions", 10, 8),
    ):
        _scheduler.add_job(
            func, trigger=IntervalTrigger(seconds=seconds), id=job_id,
            kwargs={"trading_mode": "lead"}, executor="lead",
            next_run_time=now + timedelta(seconds=offset),
            replace_existing=True, max_instances=1, coalesce=True,
        )

    _scheduler_heartbeat_job()
    _scheduler.add_job(
        _scheduler_heartbeat_job,
        trigger=IntervalTrigger(seconds=15),
        id="scheduler_heartbeat",
        name="调度器健康心跳",
        replace_existing=True,
        next_run_time=now + timedelta(seconds=15),
        max_instances=1,
        coalesce=True,
    )

    # 每5秒同步一次限价委托单状态（错峰 + 抖动）
    _scheduler.add_job(
        _sync_limit_orders_job,
        trigger=IntervalTrigger(seconds=5),
        id='sync_limit_orders',
        name='同步限价委托单状态',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=1),
        jitter=1,
        max_instances=1,
        coalesce=True,
    )

    # 每10秒执行一次策略引擎（错峰 + 抖动）
    _scheduler.add_job(
        _run_strategy_engine_job,
        trigger=IntervalTrigger(seconds=10),
        id='run_strategy_engine',
        name='执行止盈策略引擎',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=3),
        jitter=2,
        max_instances=1,
        coalesce=True,
    )

    # 每30秒低频修正一次交易所已无仓位但本地仍未平仓的订单（错峰 + 抖动）
    _scheduler.add_job(
        _reconcile_stale_open_orders_job,
        trigger=IntervalTrigger(seconds=30),
        id='reconcile_stale_open_orders',
        name='陈旧未平仓订单修正',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=5),
        jitter=4,
        max_instances=1,
        coalesce=True,
    )

    # 每10秒修正一次未完整止损保护；该任务还负责触价时的紧急市价退出。
    _scheduler.add_job(
        _reconcile_order_protection_job,
        trigger=IntervalTrigger(seconds=10),
        id='reconcile_order_protection',
        name='订单保护对账',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=5),
        jitter=1,
        max_instances=1,
        coalesce=True,
    )

    # 独立处理手动仓，不依赖策略开关；与既有 Web 保护任务错峰。
    _scheduler.add_job(
        _reconcile_external_positions_job,
        trigger=IntervalTrigger(seconds=10),
        id="reconcile_external_positions",
        name="手动仓强制止损保护",
        replace_existing=True,
        next_run_time=now + timedelta(seconds=7),
        max_instances=1,
        coalesce=True,
    )

    # 每45秒补偿一次已平仓订单结算（错峰 + 抖动）
    _scheduler.add_job(
        _reconcile_position_settlement_job,
        trigger=IntervalTrigger(seconds=45),
        id='reconcile_position_settlement',
        name='持仓结算补偿',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=13),
        jitter=5,
        max_instances=1,
        coalesce=True,
    )

    # 每60秒异步补齐开仓真实手续费，持仓页优先读入库结果，不阻塞页面。
    _scheduler.add_job(
        _sync_entry_fees_job,
        trigger=IntervalTrigger(seconds=60),
        id='sync_entry_fees',
        name='同步开仓真实手续费',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=17),
        jitter=8,
        max_instances=1,
        coalesce=True,
    )

    _scheduler.add_job(
        _dispatch_trade_notifications_job,
        trigger=IntervalTrigger(seconds=5),
        id='dispatch_trade_notifications',
        name='发送交易事件通知',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=4),
        jitter=1,
        max_instances=1,
        coalesce=True,
    )

    _scheduler.add_job(
        _dispatch_mobile_notifications_job, trigger=IntervalTrigger(seconds=10),
        id='dispatch_mobile_notifications', name='iOS信号与浮盈通知', replace_existing=True,
        next_run_time=now + timedelta(seconds=8), max_instances=1, coalesce=True,
    )

    if getattr(settings, 'LIVE_ACTIVITIES_ENABLED', False):
        _scheduler.add_job(
            _dispatch_live_activities_job, trigger=IntervalTrigger(seconds=15),
            id='dispatch_live_activities', name='iOS持仓实时活动', replace_existing=True,
            next_run_time=now + timedelta(seconds=11), max_instances=1, coalesce=True,
        )

    # 每180秒巡检一次可疑平仓记录（错峰 + 抖动）
    _scheduler.add_job(
        _audit_suspicious_closed_orders_job,
        trigger=IntervalTrigger(seconds=180),
        id='audit_suspicious_closed_orders',
        name='异常平仓巡检',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=19),
        jitter=10,
        max_instances=1,
        coalesce=True,
    )

    # 每90秒补偿一次已结束订单的残留挂单（错峰 + 抖动）
    _scheduler.add_job(
        _reconcile_closed_order_exchange_artifacts_job,
        trigger=IntervalTrigger(seconds=90),
        id='reconcile_closed_order_exchange_artifacts',
        name='已结束订单残留挂单补偿',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=23),
        jitter=6,
        max_instances=1,
        coalesce=True,
    )

    # 每60秒扫描一次自有趋势信号（仅评估已收盘K线，内部按 symbol+周期+收盘时间去重）
    _scheduler.add_job(
        _trend_signal_scan_job,
        trigger=IntervalTrigger(seconds=60),
        id='trend_signal_scan',
        name='自有趋势信号扫描',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=40),
        jitter=5,
        max_instances=1,
        coalesce=True,
    )

    # The native collector owns warming; legacy-only setups retain their job.
    if not settings.MARKET_STREAM_ENABLED:
        _scheduler.add_job(
            _warm_market_klines_job,
            trigger=IntervalTrigger(seconds=2),
            id='warm_market_klines',
            name='预热公开K线缓存',
            replace_existing=True,
            next_run_time=now + timedelta(seconds=2),
            jitter=1,
            max_instances=1,
            coalesce=True,
        )

    # 每15秒检查一次公开快照的 CDN 副本是否过期并按周期节奏补热（每轮限量）
    if settings.MARKET_SNAPSHOT_PREWARM_ENABLED:
        _scheduler.add_job(
            _prewarm_market_snapshots_job,
            trigger=IntervalTrigger(seconds=15),
            id='prewarm_market_snapshots',
            name='公开快照CDN预热',
            replace_existing=True,
            next_run_time=now + timedelta(seconds=58),
            jitter=5,
            max_instances=1,
            coalesce=True,
        )

    # 每10分钟清理一次超过保留期的 TradingView 消息（数据库仅保留最近3天）
    _scheduler.add_job(
        _purge_tradingview_messages_job,
        trigger=IntervalTrigger(minutes=10),
        id='purge_tradingview_messages',
        name='清理过期TradingView消息',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=29),
        jitter=10,
        max_instances=1,
        coalesce=True,
    )

    # 每30分钟只读检查并发送资金提醒；子账户内部划转仅由开仓弹窗确认触发。
    _scheduler.add_job(
        _balance_cap_cycle_job,
        trigger=IntervalTrigger(minutes=30),
        id='balance_cap_cycle',
        name='资金规范化提醒',
        replace_existing=True,
        next_run_time=now + timedelta(seconds=47),
        jitter=15,
        max_instances=1,
        coalesce=True,
    )

    # 每天北京时间 00:10 增量同步，避开交易所日界线附近的数据可见延迟。
    _scheduler.add_job(
        _sync_transfer_history_job,
        trigger=CronTrigger(hour=0, minute=10, timezone="Asia/Shanghai"),
        id="sync_transfer_history",
        name="增量同步转账历史",
        replace_existing=True,
        max_instances=1,
        coalesce=True,
    )

    _scheduler.start()
    logger.info("定时任务调度器已启动")


def stop_scheduler():
    """停止定时任务调度器"""
    global _scheduler

    if _scheduler is not None:
        _scheduler.shutdown()
        _scheduler = None
        logger.info("定时任务调度器已停止")
