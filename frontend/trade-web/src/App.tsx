import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  Activity,
  ArrowLeftRight,
  ArrowUpRight,
  Bell,
  ChevronDown,
  ChevronUp,
  CircleHelp,
  Cpu,
  LayoutDashboard,
  Moon,
  PanelRightClose,
  PanelRightOpen,
  RefreshCw,
  Search,
  SlidersHorizontal,
  Sparkles,
  Sun,
  Wifi,
  X,
  Zap,
} from "lucide-react";
import {
  getMarketGroups,
  type MarketRow,
  type StreamEvent,
} from "./lib/binance";
import { marketRealtime } from "./lib/realtime";
import KlineChart from "./KlineChart";
import TradePanel from "./TradePanel";
import { tradeApi, isLongSide, type PositionRow } from "./lib/tradeApi";
import { PositionsPage, HistoryPage, AccountPage } from "./Pages";
import { PositionsDock } from "./PositionsDock";
import { prefetchKlines } from "./lib/klineCache";
import { priceScaleFormatter } from "./lib/priceFormat";
import { v1Path } from "./lib/runtime";
import "./styles.css";
import ContractAnalysisAssistant from "./ContractAnalysisAssistant";
import { AccountProvider, useAccount, usePreference } from "./AccountProvider";
import { AccountControl, AccountGate } from "./AccountDialog";

type NavItem = "行情" | "持仓" | "历史" | "账户" | "信号" | "引擎";
type MarketGroup = "top20" | "alts" | "gainers" | "losers";

const money = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });
const compact = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 });

function formatPrice(price?: number) {
  if (price === undefined) return "—";
  if (price >= 1000) return money.format(price);
  if (price >= 1) return price.toFixed(2);
  return price.toFixed(5);
}

function formatDelta(value: number) {
  return `${value >= 0 ? "+" : ""}${value.toFixed(2)}%`;
}

function formatPointChange(value?: number) {
  if (value === undefined || !Number.isFinite(value)) return "—";
  const absolute = Math.abs(value);
  const digits = absolute >= 100 ? 2 : absolute >= 1 ? 4 : 6;
  return `${value >= 0 ? "+" : "−"}${absolute.toFixed(digits)}`;
}

const isTheme = (value: unknown): value is "dark" | "light" => value === "dark" || value === "light";
const isNav = (value: unknown): value is NavItem => value === "行情" || value === "持仓" || value === "历史" || value === "账户" || value === "信号" || value === "引擎";
const isGroup = (value: unknown): value is MarketGroup => value === "top20" || value === "alts" || value === "gainers" || value === "losers";
const isSymbol = (value: unknown): value is string => typeof value === "string" && /^[A-Z0-9]{1,30}USDT$/.test(value);
const isQuery = (value: unknown): value is string => typeof value === "string" && [...value].length <= 80 && !/\p{C}/u.test(value);
const isBoolean = (value: unknown): value is boolean => typeof value === "boolean";

function TerminalApp() {
  const { hydrating, user } = useAccount();
  const [theme, setTheme] = usePreference<"dark" | "light">("theme", document.documentElement.dataset.theme === "light" ? "light" : "dark", isTheme);
  const [activeNav, setActiveNav] = usePreference<NavItem>("activeNav", "行情", isNav);
  const [group, setGroup] = usePreference<MarketGroup>("marketGroup", "top20", isGroup);
  const [markets, setMarkets] = useState<{ top20: MarketRow[]; alts: MarketRow[]; all: MarketRow[] }>({ top20: [], alts: [], all: [] });
  const [selectedSymbol, setSelectedSymbol] = usePreference("selectedSymbol", "BTCUSDT", isSymbol);
  const [chartPreference] = usePreference<{ interval: string }>("chart", { interval: "15m" });
  const [query, setQuery] = usePreference("marketQuery", "", isQuery);
  const [showInsightPanel, setShowInsightPanel] = usePreference("showInsightPanel", true, isBoolean);
  const [marketStatus, setMarketStatus] = useState<"loading" | "ready" | "error">("loading");
  const [marketAttempt, setMarketAttempt] = useState(0);
  const [connection, setConnection] = useState<"connecting" | "live" | "disconnected">("connecting");
  const [latency, setLatency] = useState<number | null>(null);
  const [positionCount, setPositionCount] = useState(0);
  const [dockOpen, setDockOpen] = useState(false);
  const [dockPositions, setDockPositions] = useState<PositionRow[]>([]);
  const [wsH, setWsH] = useState(0);
  const wsRef = useRef<HTMLElement | null>(null);
  const [diagOpen, setDiagOpen] = useState(false);
  const [tlsProbe, setTlsProbe] = useState<{ ok: boolean; ms: number } | null>(null);
  const [tickerOk, setTickerOk] = useState(false);
  const [klineOk, setKlineOk] = useState(false);
  const [showAssistant, setShowAssistant] = useState(false);
  const [insightMode, setInsightMode] = useState<"trade" | "pulse">("trade");
  const [accountFocus, setAccountFocus] = useState<{ kind: "stop-loss" | "strategy"; at: number } | null>(null);
  const [stopPriceRequest, setStopPriceRequest] = useState<{ value: string; at: number } | null>(null);
  const pendingTickersRef = useRef(new Map<string, { price: number; change: number }>());
  const tickerSymbolsRef = useRef<readonly string[]>([]);
  const selectedSymbolRef = useRef(selectedSymbol);
  const tickerSymbolsKey = useMemo(() => markets.all.map((row) => row.symbol).join(","), [markets.all]);
  useEffect(() => { tickerSymbolsRef.current = tickerSymbolsKey ? tickerSymbolsKey.split(",") : []; }, [tickerSymbolsKey]);
  useEffect(() => { selectedSymbolRef.current = selectedSymbol; }, [selectedSymbol]);
  const navRef = useRef<HTMLElement | null>(null);
  const [structuresContainer, setStructuresContainer] = useState<HTMLElement | null>(null);
  const assistantOpener = useRef<HTMLElement | null>(null);

  function openAssistant() {
    assistantOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setShowAssistant(true);
  }

  function toggleTheme() {
    setTheme((current) => current === "dark" ? "light" : "dark");
  }

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", theme === "light" ? "#ffffff" : "#111214");
    try {
      // Cache only signed-out/personal theme for first paint. Guest browsing
      // must not persist a preference locally or to the shared account.
      localStorage.setItem("market-theme", theme);
    } catch {
      // Keep the active theme even if the browser blocks saving preferences.
    }
  }, [theme, user]);

  useEffect(() => {
    if (!user) {
      setMarketStatus("loading");
      setMarkets({ top20: [], alts: [], all: [] });
      return;
    }
    let cancelled = false;
    getMarketGroups().then((data) => {
      if (cancelled) return;
      setMarkets({ top20: data.top20, alts: data.alts, all: data.all });
      setMarketStatus("ready");
    }).catch(() => { if (!cancelled) setMarketStatus("error"); });
    return () => { cancelled = true; };
  }, [marketAttempt, user]);

  useEffect(() => {
    if (!user || hydrating || marketStatus !== "ready" || !markets.all.length) return;
    setSelectedSymbol((current) => markets.all.some((row) => row.symbol === current) ? current : markets.top20[0]?.symbol ?? current);
  }, [hydrating, marketStatus, markets.all, markets.top20, setSelectedSymbol, user]);

  useEffect(() => {
    if (marketStatus !== "ready") return;
    const timers = markets.top20.slice(0, 5).map((row, index) =>
      window.setTimeout(() => prefetchKlines(row.symbol, chartPreference.interval), 400 + index * 250));
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [marketStatus, chartPreference.interval]);

  const activeMarkets = useMemo(() => {
    const rows = group === "top20" ? markets.top20 : group === "alts" ? markets.alts : [...markets.all].sort((a, b) => group === "gainers" ? b.priceChangePercent - a.priceChangePercent : a.priceChangePercent - b.priceChangePercent);
    const normalized = query.trim().toUpperCase();
    return normalized ? rows.filter((row) => row.symbol.includes(normalized) || row.baseAsset.includes(normalized)) : rows;
  }, [group, markets, query]);
  const selected = markets.all.find((row) => row.symbol === selectedSymbol);
  const priceMap = useMemo(() => Object.fromEntries(markets.all.map((row) => [row.symbol, row.lastPrice])), [markets.all]);
  const selectedPrice = selected?.lastPrice;
  const selectedPercent = selected?.priceChangePercent;
  const selectedPointChange = selectedPrice !== undefined && selectedPercent !== undefined && selectedPercent > -100
    ? selectedPrice * selectedPercent / (100 + selectedPercent) : undefined;
  const panelVisible = showInsightPanel || showAssistant;
  const connectionLabel = { connecting: "连接中", live: "实时连接", disconnected: "连接中断" }[connection];
  const latencyInfo = (() => {
    if (connection === "disconnected") return { text: "-- ms", tone: "bad" };
    if (latency === null) return { text: "-- ms", tone: "fair" };
    const ms = Math.min(999, Math.max(0, Math.round(latency)));
    return { text: `${ms} ms`, tone: ms < 200 ? "good" : ms < 500 ? "fair" : "bad" };
  })();
  const refreshPositions = useCallback(() => tradeApi.positions().then((rows) => { setPositionCount(rows.length); setDockPositions(rows); }).catch(() => undefined), []);
  useEffect(() => {
    if (!user) return;
    let cancelled = false;
    const loadCount = () => { if (!cancelled) void refreshPositions(); };
    void loadCount();
    const timer = window.setInterval(loadCount, 10_000);
    return () => { cancelled = true; window.clearInterval(timer); };
  }, [user]);

  async function probeTls() {
    const started = performance.now();
    try {
      const response = await fetch(v1Path("/health"), { cache: "no-store", signal: AbortSignal.timeout(8000) });
      setTlsProbe({ ok: response.ok, ms: Math.round(performance.now() - started) });
    } catch {
      setTlsProbe({ ok: false, ms: Math.round(performance.now() - started) });
    }
  }
  useEffect(() => { if (diagOpen) void probeTls(); }, [diagOpen]);

  const connStages = [
    { name: "域名 / TLS / 证书", ok: tlsProbe?.ok ?? null, detail: tlsProbe ? (tlsProbe.ok ? `握手 ${tlsProbe.ms}ms` : "握手失败/超时") : "待检测" },
    { name: "REST 行情目录", ok: marketStatus === "ready" ? true : marketStatus === "error" ? false : null, detail: marketStatus === "ready" ? "已同步" : marketStatus === "error" ? "同步失败" : "同步中" },
    { name: "WS 握手 / 鉴权", ok: connection === "live" ? true : connection === "disconnected" ? false : null, detail: connection === "live" ? "已连接" : connection === "disconnected" ? "被拒/断开" : "连接中" },
    { name: "WS ticker 推送", ok: tickerOk ? true : connection === "disconnected" ? false : null, detail: tickerOk ? "收到报价" : "未收到" },
    { name: "WS kline 推送", ok: klineOk ? true : connection === "disconnected" ? false : null, detail: klineOk ? "收到K线" : "未收到" },
  ];
  useEffect(() => {
    if (!user) {
      setConnection("connecting");
      return;
    }
    setConnection("connecting");
    // 订阅只随登录建立一次：ticker 过滤走 ref 动态列表、kline 用通配，
    // 列表/切币变化不再触发重订阅（活连接重发订阅帧，无断档）。
    const unsubscribe = marketRealtime.subscribe({ symbol: "*", interval: "15m", tickerSymbols: () => (tickerSymbolsRef.current.length ? tickerSymbolsRef.current : [selectedSymbolRef.current]), handler: (event: StreamEvent) => {
      if (event.type === "disconnected" || event.type === "error") { setConnection("disconnected"); setLatency(null); setTickerOk(false); setKlineOk(false); }
      if (event.type === "latency") { setLatency(event.ms); setConnection("live"); }
      if (event.type === "kline") setKlineOk(true);
      if (event.type === "ticker") {
        setConnection("live");
        setTickerOk(true);
        pendingTickersRef.current.set(event.symbol, { price: event.price, change: event.changePercent });
      }
    } });
    // 后端单条 !ticker@arr 已采集全合约，此处订阅不新增币安负载；UI 500ms 聚合避免逐消息渲染。
    const flush = window.setInterval(() => {
      const pending = pendingTickersRef.current;
      if (!pending.size) return;
      const batch = new Map(pending);
      pending.clear();
      setMarkets((current) => {
        const update = (rows: MarketRow[]) => rows.map((row) => {
          const tick = batch.get(row.symbol);
          return tick ? { ...row, lastPrice: tick.price, priceChangePercent: tick.change } : row;
        });
        return { top20: update(current.top20), alts: update(current.alts), all: update(current.all) };
      });
    }, 500);
    return () => { window.clearInterval(flush); unsubscribe(); };
  }, [user]);

  useEffect(() => {
    const el = wsRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWsH(el.clientHeight));
    ro.observe(el);
    setWsH(el.clientHeight);
    return () => ro.disconnect();
  }, []);
  // 主导航首项与 K 线区左缘竖直对齐：按实测差值补 margin，随布局变化重算。
  useLayoutEffect(() => {
    const align = () => {
      const nav = navRef.current;
      const chart = document.querySelector(".chart-workspace");
      if (!nav || !chart || window.innerWidth < 920) { if (nav) nav.style.marginLeft = "0px"; return; }
      const chartRect = chart.getBoundingClientRect();
      if (!chartRect.width) return;
      nav.style.marginLeft = "0px";
      const delta = chartRect.left - nav.getBoundingClientRect().left;
      nav.style.marginLeft = `${Math.round(delta)}px`;
    };
    align();
    const chart = document.querySelector(".chart-workspace");
    const observer = new ResizeObserver(align);
    if (chart) observer.observe(chart);
    window.addEventListener("resize", align);
    return () => { observer.disconnect(); window.removeEventListener("resize", align); };
  }, [activeNav, panelVisible, showAssistant]);

  if (hydrating || !user) return <AccountGate loading={hydrating} />;

  return (
    <div className="terminal-shell">
      <header className="topbar">
        <div className="brand-lockup"><img className="brand-logo" src={`${import.meta.env.BASE_URL}favicon.png`} alt="ORBITAL" /><div><div className="brand-name">ORBITAL</div><div className="brand-sub">MARKET INTELLIGENCE</div></div></div>
        <nav className="main-nav" aria-label="主导航" ref={navRef}>
          {(["行情", "信号", "引擎", "持仓", "历史", "账户"] as NavItem[]).map((item) => <button key={item} className={`nav-item ${activeNav === item ? "active" : ""}`} onClick={() => setActiveNav(item)}>{item}{item === "信号" && <span className="nav-badge">LIVE</span>}{item === "持仓" && positionCount > 0 && <span className="nav-pos-count" aria-label={`${positionCount} 个持仓`}>{positionCount}</span>}</button>)}
        </nav>
        <div className="top-actions">
          <div className={`connection-status is-${latencyInfo.tone}`} role="button" tabIndex={0} title="点击查看连接分层诊断" onClick={() => setDiagOpen((open) => !open)} onKeyDown={(event) => { if (event.key === "Enter") setDiagOpen((open) => !open); }}><span className={`status-light ${connection === "live" ? "is-live" : ""}`} /> {connectionLabel}<span className="conn-latency">{latencyInfo.text}</span></div>
          {diagOpen && <div className="conn-diag" role="dialog" aria-label="连接分层诊断">
            <header><strong>连接分层诊断</strong><button type="button" onClick={() => void probeTls()}>重新检测</button><button type="button" aria-label="关闭" onClick={() => setDiagOpen(false)}><X size={13} /></button></header>
            {connStages.map((stage) => <div key={stage.name} className="conn-diag-row">
              <span className={`conn-dot ${stage.ok === true ? "ok" : stage.ok === false ? "bad" : "idle"}`} />
              <span className="conn-diag-name">{stage.name}</span>
              <span className={`conn-diag-detail ${stage.ok === false ? "bad" : ""}`}>{stage.detail}</span>
            </div>)}
          </div>}
          <button
            className="theme-toggle"
            type="button"
            aria-label={theme === "dark" ? "切换为白色主题" : "切换为黑色主题"}
            title={theme === "dark" ? "切换为白色主题" : "切换为黑色主题"}
            onClick={toggleTheme}
          >
            {theme === "dark" ? <Sun size={16} aria-hidden="true" /> : <Moon size={16} aria-hidden="true" />}
          </button>
          <button className="icon-btn" aria-label="通知"><Bell size={16} /></button>
          <button className="icon-btn" aria-label="帮助"><CircleHelp size={16} /></button>
          <AccountControl />
        </div>
      </header>

      <div className={`workspace${panelVisible ? "" : " without-insight"}`} hidden={activeNav !== "行情"}>
        <aside className="market-rail">
          <div className="rail-heading">
            <div><div className="eyebrow">MARKETS</div><h2>市场扫描</h2></div>
            <div className="rail-heading-actions">
              {insightMode === "pulse" && <button className="assistant-entry market-assistant-entry" type="button" onClick={openAssistant} aria-expanded={showAssistant} aria-controls="contract-analysis-assistant">合约分析助手</button>}
              <button className="rail-config" aria-label="筛选"><SlidersHorizontal size={15} /></button>
            </div>
          </div>
          <div className="market-tabs"><button className={group === "top20" ? "active" : ""} onClick={() => setGroup("top20")}>市值前 20</button><button className={group === "alts" ? "active" : ""} onClick={() => setGroup("alts")}>山寨</button><button className={group === "gainers" ? "active" : ""} onClick={() => setGroup("gainers")}>涨幅榜</button><button className={group === "losers" ? "active" : ""} onClick={() => setGroup("losers")}>跌幅榜</button></div>
          <div className="search-box"><Search size={15} /><input value={query} maxLength={80} onChange={(event) => setQuery(event.target.value.replace(/\p{C}/gu, ""))} placeholder="搜索交易对" />{query && <button className="clear-search" onClick={() => setQuery("")} aria-label="清除"><X size={13} /></button>}</div>
          <div className="rail-label-row"><span>交易对</span><span>最新价 / 24H</span></div>
          <div className="market-list">
            {marketStatus === "loading" && <div className="loading-row" role="status"><RefreshCw size={14} className="spin" /> 正在同步币安合约…</div>}
            {marketStatus === "error" && (
              <div className="loading-row">
                <span role="status">币安行情同步失败</span>
                <button className="market-retry" type="button" onClick={() => {
                  setMarketStatus("loading");
                  setMarketAttempt((previous) => previous + 1);
                }}>重试</button>
              </div>
            )}
            {activeMarkets.map((row) => <button key={row.symbol} className={`market-row ${selectedSymbol === row.symbol ? "selected" : ""}`} onClick={() => setSelectedSymbol(row.symbol)} onMouseEnter={() => prefetchKlines(row.symbol, chartPreference.interval)}><div className="market-name"><strong>{row.baseAsset}<span>/USDT</span></strong><small>{compact.format(row.quoteVolume)} vol</small></div><div className="market-quote"><strong>{formatPrice(row.lastPrice)}</strong><small className={row.priceChangePercent >= 0 ? "positive" : "negative"}>{formatDelta(row.priceChangePercent)}</small></div></button>)}</div>
          <div className="rail-footer"><div><span className={`status-light ${marketStatus === "ready" ? "is-live" : ""}`} /> Binance Futures</div><span>{activeMarkets.length} 个合约</span></div>
        </aside>
        <main className="chart-workspace" ref={wsRef}>
          <div className="chart-underlay" inert={showAssistant ? true : undefined}><KlineChart symbol={selectedSymbol} insightToggle={!showAssistant && <button className="insight-toggle" type="button" aria-label={showInsightPanel ? "收起盘面速览" : "显示盘面速览"} title={showInsightPanel ? "收起盘面速览" : "显示盘面速览"} aria-pressed={showInsightPanel} onClick={() => setShowInsightPanel((show) => !show)}>{showInsightPanel ? <PanelRightClose size={15} /> : <PanelRightOpen size={15} />}</button>} theme={theme} onSymbolChange={setSelectedSymbol} onStopPrice={(p) => setStopPriceRequest({ value: priceScaleFormatter(p), at: Date.now() })} /></div>
          <PositionsDock rows={dockPositions} prices={priceMap} open={dockOpen} height={Math.round(wsH * 0.3)} onToggle={() => setDockOpen((open) => !open)} onOpenSymbol={setSelectedSymbol} onChanged={() => void refreshPositions()} />
          {showAssistant && <ContractAnalysisAssistant key={selectedSymbol} symbol={selectedSymbol} baseAsset={selected?.baseAsset ?? selectedSymbol.replace(/USDT$/, "")} structuresContainer={structuresContainer} returnFocusTo={assistantOpener.current} onClose={() => setShowAssistant(false)} />}
        </main>
        {panelVisible && <aside className="insight-panel" ref={setStructuresContainer} aria-labelledby={showAssistant ? "assistant-structures-title" : "market-pulse-title"}>
          <div hidden={showAssistant}>
          <header className="panel-heading">
            <div>
              <div className="eyebrow">MARKET PULSE</div>
              <h2 id="market-pulse-title">{insightMode === "trade" ? "交易" : "盘面速览"}</h2>
            </div>
            <button className="pulse-mode-toggle" type="button" aria-pressed={insightMode === "trade"} title={insightMode === "trade" ? "切换到盘面" : "切换到交易"} onClick={() => { setInsightMode((mode) => (mode === "trade" ? "pulse" : "trade")); setShowAssistant(false); }}><ArrowLeftRight size={13} aria-hidden="true" /><span>{insightMode === "trade" ? "盘面" : "交易"}</span></button>
          </header>
          <div hidden={insightMode !== "trade"}><TradePanel symbol={selectedSymbol} price={selectedPrice} visible={insightMode === "trade" && activeNav === "行情"} stopPriceRequest={stopPriceRequest} onNavigate={(kind) => { setAccountFocus({ kind, at: Date.now() }); setActiveNav("账户"); }} /></div>
          <div hidden={insightMode !== "pulse"}>
          <div className="price-card" aria-label="当前价格与涨跌">
            <div className="price-card-top">
              <div className="price-card-coin">{selected?.baseAsset ?? selectedSymbol.replace(/USDT$/, "")}</div>
              <div className={`price-card-change ${selectedPercent !== undefined && selectedPercent >= 0 ? "positive" : "negative"}`}>
                <span>{formatPointChange(selectedPointChange)}</span>
                <span>{selectedPercent === undefined ? "—" : formatDelta(selectedPercent)}</span>
              </div>
            </div>
            <div className="price-card-label">当前价格</div>
            <strong className="price-card-number">{formatPrice(selectedPrice)}</strong>
          </div>
          <div className="sentiment-card">
            <div className="sentiment-top"><span>短线情绪</span><span className="sentiment-status">偏多</span></div>
            <div className="sentiment-meter"><div className="meter-fill" /><div className="meter-notch" /></div>
            <div className="meter-labels"><span>恐惧</span><strong>68 / 100</strong><span>贪婪</span></div>
          </div>
          <div className="insight-block">
            <div className="insight-label"><Zap size={14} /> 动能状态</div>
            <div className="insight-value">上涨动能 <span>强</span></div>
            <div className="mini-bars">
              {[24, 40, 38, 58, 46, 65, 72, 61, 84, 76, 91, 87].map((height, i) => <i key={i} style={{ height: `${height}%` }} className={i > 7 ? "hot" : ""} />)}
            </div>
          </div>
          <div className="insight-block">
            <div className="insight-label"><Activity size={14} /> 关键位置</div>
            <div className="key-level"><span>阻力</span><strong>{formatPrice(selectedPrice === undefined ? undefined : selectedPrice * 1.021)}</strong><span className="negative">+2.1%</span></div>
            <div className="key-level"><span>现价</span><strong className="gold-text">{formatPrice(selectedPrice)}</strong><span className="positive">—</span></div>
            <div className="key-level"><span>支撑</span><strong>{formatPrice(selectedPrice === undefined ? undefined : selectedPrice * .976)}</strong><span className="positive">−2.4%</span></div>
          </div>
          <div className="insight-block signal-block">
            <div className="insight-label"><Sparkles size={14} /> 系统信号</div>
            <div className="signal-row">
              <span className="signal-badge">多</span>
              <div><strong>趋势延续</strong><small>EMA 结构保持完整</small></div>
              <span className="signal-time">2m 前</span>
            </div>
          </div>
          </div>
          {insightMode === "pulse" && <button className="assistant-entry panel-more" type="button" onClick={openAssistant} aria-expanded={showAssistant} aria-controls="contract-analysis-assistant">
            合约分析助手 <ArrowUpRight size={16} aria-hidden="true" />
          </button>}
          </div>
        </aside>}
      </div>
      {activeNav === "持仓" && <div className="pg-scroll"><PositionsPage prices={priceMap} onOpenSymbol={(symbol) => { setSelectedSymbol(symbol); setActiveNav("行情"); }} /></div>}
      {activeNav === "历史" && <div className="pg-scroll"><HistoryPage /></div>}
      {activeNav === "账户" && <div className="pg-scroll"><AccountPage focus={accountFocus} /></div>}
      {(activeNav === "信号" || activeNav === "引擎") && <section className="empty-state"><div className="empty-orbit"><Cpu size={34} /></div><h1>{activeNav}模块即将上线</h1><p>核心数据层已连接 Binance Futures。切换回行情查看实时盘面。</p><button onClick={() => setActiveNav("行情")}><LayoutDashboard size={15} /> 返回行情</button></section>}
      <footer className="statusbar"><span><Wifi size={13} /> 币安 API <strong>{marketStatus === "ready" ? "已同步" : marketStatus === "loading" ? "同步中" : "同步失败"}</strong></span><span><Activity size={13} /> WebSocket <strong className={connection === "live" ? "positive" : ""}>{connectionLabel}</strong></span><button type="button" className="statusbar-dock-toggle" aria-expanded={dockOpen} aria-label={dockOpen ? "收起持仓列表" : "展开持仓列表"} onClick={() => setDockOpen((open) => !open)}>{dockOpen ? <ChevronDown size={13} /> : <ChevronUp size={13} />} 持仓</button><span className="statusbar-right">ORBITAL TERMINAL <b>v0.1.0</b></span></footer>
    </div>
  );
}

export default function App() {
  return <AccountProvider><AuthenticatedApp /></AccountProvider>;
}

function AuthenticatedApp() {
  const { user, hydrating } = useAccount();
  if (hydrating || !user) return <AccountGate loading={hydrating} />;
  return <TerminalApp />;
}
