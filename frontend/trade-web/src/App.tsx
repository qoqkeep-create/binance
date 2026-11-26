import { useEffect, useMemo, useRef, useState } from "react";
import {
  Activity,
  ArrowUpRight,
  Bell,
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
  BinanceStream,
  getMarketGroups,
  type MarketRow,
  type StreamEvent,
} from "./lib/binance";
import KlineChart from "./KlineChart";
import { PositionsPage, HistoryPage, AccountPage } from "./Pages";
import { prefetchKlines } from "./lib/klineCache";
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
  const [showAssistant, setShowAssistant] = useState(false);
  const [insightMode, setInsightMode] = useState<"trade" | "pulse">("trade");
  const [chartActions, setChartActions] = useState<HTMLDivElement | null>(null);
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
      if (user?.role !== "guest") localStorage.setItem("market-theme", theme);
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
  useEffect(() => {
    if (!user) {
      setConnection("connecting");
      return;
    }
    setConnection("connecting");
    const stream = new BinanceStream(selectedSymbol, "15m", (event: StreamEvent) => {
      if (event.type === "disconnected" || event.type === "error") setConnection("disconnected");
      if (event.type === "ticker") {
        setConnection("live");
        setMarkets((current) => {
          const update = (rows: MarketRow[]) => rows.map((row) => row.symbol === event.symbol ? { ...row, lastPrice: event.price, priceChangePercent: event.changePercent } : row);
          return { top20: update(current.top20), alts: update(current.alts), all: update(current.all) };
        });
      }
    });
    stream.connect();
    return () => stream.close();
  }, [selectedSymbol, user]);

  if (hydrating || !user) return <AccountGate loading={hydrating} />;

  return (
    <div className="terminal-shell">
      <header className="topbar">
        <div className="brand-lockup"><div className="brand-glyph"><span /><span /><span /></div><div><div className="brand-name">ORBITAL</div><div className="brand-sub">MARKET INTELLIGENCE</div></div></div>
        <nav className="main-nav" aria-label="主导航">
          {(["行情", "信号", "引擎", "持仓", "历史", "账户"] as NavItem[]).map((item) => <button key={item} className={`nav-item ${activeNav === item ? "active" : ""}`} onClick={() => setActiveNav(item)}>{item}{item === "信号" && <span className="nav-badge">LIVE</span>}</button>)}
        </nav>
        <div className="top-actions">
          <div className="connection-status"><span className={`status-light ${connection === "live" ? "is-live" : ""}`} /> {connectionLabel}</div>
          <div className="chart-actions" ref={setChartActions} hidden={activeNav !== "行情" || showAssistant} />
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
              <button className="assistant-entry market-assistant-entry" type="button" onClick={openAssistant} aria-expanded={showAssistant} aria-controls="contract-analysis-assistant">合约分析助手</button>
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
            {activeMarkets.map((row, index) => <button key={row.symbol} className={`market-row ${selectedSymbol === row.symbol ? "selected" : ""}`} onClick={() => setSelectedSymbol(row.symbol)} onMouseEnter={() => prefetchKlines(row.symbol, chartPreference.interval)}><div className="market-rank">{row.rank ?? String(index + 1).padStart(2, "0")}</div><div className="market-name"><strong>{row.baseAsset}<span>/USDT</span></strong><small>{compact.format(row.quoteVolume)} vol</small></div><div className="market-quote"><strong>{formatPrice(row.lastPrice)}</strong><small className={row.priceChangePercent >= 0 ? "positive" : "negative"}>{formatDelta(row.priceChangePercent)}</small></div></button>)}</div>
          <div className="rail-footer"><div><span className={`status-light ${marketStatus === "ready" ? "is-live" : ""}`} /> Binance Futures</div><span>{activeMarkets.length} 个合约</span></div>
        </aside>
        <main className="chart-workspace">
          <div className="chart-underlay" inert={showAssistant ? true : undefined}><KlineChart symbol={selectedSymbol} actionsContainer={chartActions} insightToggle={!showAssistant && <button className="insight-toggle" type="button" aria-label={showInsightPanel ? "收起盘面速览" : "显示盘面速览"} title={showInsightPanel ? "收起盘面速览" : "显示盘面速览"} aria-pressed={showInsightPanel} onClick={() => setShowInsightPanel((show) => !show)}>{showInsightPanel ? <PanelRightClose size={15} /> : <PanelRightOpen size={15} />}</button>} theme={theme} onSymbolChange={setSelectedSymbol} readOnly={user.role === "guest"} /></div>
          {showAssistant && <ContractAnalysisAssistant key={selectedSymbol} symbol={selectedSymbol} baseAsset={selected?.baseAsset ?? selectedSymbol.replace(/USDT$/, "")} structuresContainer={structuresContainer} returnFocusTo={assistantOpener.current} onClose={() => setShowAssistant(false)} />}
        </main>
        {panelVisible && <aside className="insight-panel" ref={setStructuresContainer} aria-labelledby={showAssistant ? "assistant-structures-title" : "market-pulse-title"}>
          <div hidden={showAssistant}>
          <header className="panel-heading">
            <div className="eyebrow">MARKET PULSE</div>
            <h2 id="market-pulse-title">盘面速览</h2>
          </header>
          <div className="price-card" aria-label="当前价格与涨跌">
            <span className="price-card-coin">{selected?.baseAsset ?? selectedSymbol.replace(/USDT$/, "")}</span>
            <div className="price-card-right">
              <strong className="price-card-number">{formatPrice(selectedPrice)}</strong>
              <div className={`price-card-change ${selectedPercent !== undefined && selectedPercent >= 0 ? "positive" : "negative"}`}>
                <span>{formatPointChange(selectedPointChange)}</span>
                <span>{selectedPercent === undefined ? "—" : formatDelta(selectedPercent)}</span>
              </div>
            </div>
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
          <button className="assistant-entry panel-more" type="button" onClick={openAssistant} aria-expanded={showAssistant} aria-controls="contract-analysis-assistant">
            合约分析助手 <ArrowUpRight size={16} aria-hidden="true" />
          </button>
          </div>
        </aside>}
      </div>
      {activeNav === "持仓" && <div className="pg-scroll"><PositionsPage prices={priceMap} onOpenSymbol={(symbol) => { setSelectedSymbol(symbol); setActiveNav("行情"); }} /></div>}
      {activeNav === "历史" && <div className="pg-scroll"><HistoryPage /></div>}
      {activeNav === "账户" && <div className="pg-scroll"><AccountPage /></div>}
      {(activeNav === "信号" || activeNav === "引擎") && <section className="empty-state"><div className="empty-orbit"><Cpu size={34} /></div><h1>{activeNav}模块即将上线</h1><p>核心数据层已连接 Binance Futures。切换回行情查看实时盘面。</p><button onClick={() => setActiveNav("行情")}><LayoutDashboard size={15} /> 返回行情</button></section>}
      <footer className="statusbar"><span><Wifi size={13} /> 币安 API <strong>{marketStatus === "ready" ? "已同步" : marketStatus === "loading" ? "同步中" : "同步失败"}</strong></span><span><Activity size={13} /> WebSocket <strong className={connection === "live" ? "positive" : ""}>{connectionLabel}</strong></span><span className="statusbar-right">ORBITAL TERMINAL <b>v0.1.0</b></span></footer>
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
