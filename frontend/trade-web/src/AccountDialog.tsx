import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { createPortal } from "react-dom";
import { AlertCircle, ArrowRight, Check, ChevronDown, Cloud, Eye, EyeOff, LogOut, RefreshCw, UserRound, X } from "lucide-react";
import { useAccount } from "./AccountProvider";
import { AccountApiError } from "./lib/account";
import "./account.css";

type DialogMode = "login" | "register";
const syncLabels = { "signed-out": "尚未登录", loading: "正在读取云端设置", syncing: "正在保存设置", saved: "云端已保存", guest: "游客只读 · 不保存设置", error: "同步未完成" };

export function AccountControl() {
  const { user, hydrating, authPending, syncStatus, error, logout, retrySync } = useAccount();
  const [mode, setMode] = useState<DialogMode | null>(null);
  const [profileOpen, setProfileOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const dialogOpener = useRef<HTMLElement | null>(null);
  const lastUser = useRef(user?.id);

  useEffect(() => {
    if (user?.id && user.id !== lastUser.current) setMode(null);
    lastUser.current = user?.id;
    if (!user) setProfileOpen(false);
  }, [user]);

  useEffect(() => {
    if (!profileOpen) return;
    const outside = (event: PointerEvent) => { if (!menuRef.current?.contains(event.target as Node)) setProfileOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") { event.stopPropagation(); setProfileOpen(false); triggerRef.current?.focus(); } };
    document.addEventListener("pointerdown", outside);
    window.addEventListener("keydown", key, true);
    return () => { document.removeEventListener("pointerdown", outside); window.removeEventListener("keydown", key, true); };
  }, [profileOpen]);

  function openDialog(next: DialogMode) {
    dialogOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setMode(next);
  }

  return <>
    <div className="account-control" ref={menuRef}>
      {user ? <>
        <button ref={triggerRef} type="button" className="account-profile-trigger" onClick={() => setProfileOpen((open) => !open)} aria-expanded={profileOpen} aria-controls="account-profile-panel" aria-label={`${user.displayName}，账户与云端设置`}>
          <span className="account-avatar">{user.role === "guest" ? "游" : user.displayName.slice(0, 1).toUpperCase()}</span><span className="account-trigger-name">{user.displayName}</span><span className={`account-sync-dot is-${syncStatus}`} /><ChevronDown size={12} />
        </button>
        {profileOpen && <section className="account-profile-panel" id="account-profile-panel" aria-label="账户与云端同步">
          <div className="account-profile-heading"><span className="account-avatar large">{user.role === "guest" ? "游" : user.displayName.slice(0, 1).toUpperCase()}</span><div><strong>{user.displayName}</strong><span>{user.email ?? `@${user.username}`}</span></div><span className="account-role">{user.role === "guest" ? "游客" : "个人账户"}</span></div>
          <div className={`account-cloud-status is-${syncStatus}`} role="status"><Cloud size={15} /><span>{syncLabels[syncStatus]}</span>{syncStatus === "saved" && <Check size={13} />}{syncStatus === "guest" && <UserRound size={13} />}{(syncStatus === "syncing" || syncStatus === "loading") && <RefreshCw size={12} className="spin" />}</div>
          {error && <div className="account-profile-error"><span>{error}</span><button type="button" onClick={retrySync} disabled={hydrating || authPending}><RefreshCw size={11} /> 重试同步</button></div>}
          {syncStatus === "error" && !error && <button className="account-retry-sync" type="button" onClick={retrySync}>重试同步 <RefreshCw size={12} /></button>}
          <p className="account-sync-description">{user.role === "guest" ? "游客可以浏览行情与分析；主题、交易对和筛选仅在本次浏览中生效，不会写入账户。" : "本页面的主题、交易对、筛选、助手周期与图表周期随账户保存。TradingView 内部画线和自定义指标不包含在此同步中。"}</p>
          {user.role === "guest" && <p className="account-guest-note">游客模式只读，当前浏览中的筛选和界面变化不会保存；注册独立账户可保存个人偏好。</p>}
          <button className="account-logout" type="button" disabled={authPending} onClick={() => { void logout().then(() => setProfileOpen(false)).catch(() => undefined); }}><LogOut size={14} />{authPending ? "正在退出…" : "退出登录"}</button>
        </section>}
      </> : <button ref={triggerRef} type="button" className="account-login-entry" onClick={() => openDialog("login")} aria-haspopup="dialog"><UserRound size={15} /><span>{hydrating ? "账户" : "登录 / 注册"}</span></button>}
    </div>
    {mode && <AccountDialog initialMode={mode} onClose={() => setMode(null)} returnFocusTo={dialogOpener.current} />}
  </>;
}

export default function AccountDialog({ initialMode, onClose, returnFocusTo, presentation = "modal" }: { initialMode: DialogMode; onClose: () => void; returnFocusTo: HTMLElement | null; presentation?: "modal" | "page" }) {
  const { login, register, authPending } = useAccount();
  const [mode, setMode] = useState(initialMode);
  const [identifier, setIdentifier] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const titleId = useId();
  const errorId = useId();
  const passwordId = useId();
  const busy = submitting || authPending;

  useEffect(() => {
    const background = document.getElementById("root");
    const wasInert = background?.inert ?? false;
    if (background) background.inert = true;
    inputRef.current?.focus();
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopImmediatePropagation();
        onCloseRef.current();
      }
      if (event.key === "Tab") {
        const focusable = dialogRef.current?.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled]), a[href], [tabindex="0"]');
        if (!focusable?.length) return;
        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        const outside = !dialogRef.current?.contains(document.activeElement);
        if (event.shiftKey && (document.activeElement === first || outside)) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && (document.activeElement === last || outside)) { event.preventDefault(); first.focus(); }
      }
    };
    window.addEventListener("keydown", keydown, true);
    return () => {
      if (background) background.inert = wasInert;
      window.removeEventListener("keydown", keydown, true);
      if (returnFocusTo?.isConnected) returnFocusTo.focus();
    };
  }, []);

  function switchMode(next: DialogMode) {
    setMode(next);
    setError("");
    setPassword("");
    setConfirmation("");
    setShowPassword(false);
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    setError("");
    const normalized = identifier.trim();
    if (!normalized || !password) { setError("请填写账户和密码。"); return; }
    if (mode === "register") {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized) || normalized.length > 254) { setError("请输入有效的邮箱地址。"); return; }
      if ([...password].length < 8 || [...password].length > 128) { setError("密码需要 8–128 个字符。"); return; }
      if (password !== confirmation) { setError("两次输入的密码不一致。"); return; }
      if ([...displayName.trim()].length > 80) { setError("昵称最多 80 个字符。"); return; }
    }
    setSubmitting(true);
    try {
      if (mode === "register") await register({ email: normalized.toLowerCase(), password, ...(displayName.trim() ? { displayName: displayName.trim() } : {}) });
      else await login(normalized, password);
      setPassword("");
      setConfirmation("");
      onClose();
    } catch (error) { setError(error instanceof AccountApiError ? error.message : "暂时无法登录，请检查网络后重试。"); }
    finally { setSubmitting(false); }
  }

  async function enterGuest() {
    if (busy) return;
    setError("");
    setSubmitting(true);
    try { await login("88888888", "88888888"); onClose(); }
    catch (error) { setError(error instanceof AccountApiError ? error.message : "游客登录暂时不可用，请稍后重试。"); }
    finally { setSubmitting(false); }
  }

  return createPortal(<div className={`account-modal-backdrop ${presentation === "page" ? "account-page-backdrop" : ""}`} onPointerDown={(event) => { if (presentation !== "page" && event.target === event.currentTarget) onClose(); }}>
    {presentation === "page" && <div className="account-page-brand" aria-hidden="true"><div className="account-page-glyph"><span /><span /><span /></div><div><strong>ORBITAL</strong><small>MARKET INTELLIGENCE</small></div></div>}
    <div className="account-dialog" ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby={titleId}>
      <header className="account-dialog-heading"><div><span className="account-eyebrow">YOUR WORKSPACE</span><h2 id={titleId}>{mode === "login" ? "欢迎回来" : "创建个人账户"}</h2><p>{mode === "login" ? "登录后，继续你的市场观察。" : "用邮箱注册，保存自己的页面偏好。"}</p></div>{presentation !== "page" && <button type="button" className="account-modal-close" onClick={onClose} aria-label="关闭账户窗口"><X size={18} /></button>}</header>
      <div className="account-auth-tabs" role="tablist" aria-label="账户操作"><button type="button" role="tab" aria-selected={mode === "login"} className={mode === "login" ? "active" : ""} onClick={() => switchMode("login")} disabled={busy}>登录</button><button type="button" role="tab" aria-selected={mode === "register"} className={mode === "register" ? "active" : ""} onClick={() => switchMode("register")} disabled={busy}>邮箱注册</button></div>
      <form onSubmit={submit} className="account-form" aria-describedby={error ? errorId : undefined}>
        <label><span>{mode === "login" ? "邮箱 / 用户名" : "邮箱"}</span><input ref={inputRef} type={mode === "register" ? "email" : "text"} value={identifier} onChange={(event) => setIdentifier(event.target.value)} autoComplete={mode === "register" ? "email" : "username"} placeholder={mode === "register" ? "you@example.com" : "输入邮箱或用户名"} maxLength={254} disabled={busy} required /></label>
        {mode === "register" && <label><span>昵称 <small>选填</small></span><input value={displayName} onChange={(event) => setDisplayName(event.target.value)} autoComplete="nickname" placeholder="你希望显示的名字" maxLength={80} disabled={busy} /></label>}
        <label htmlFor={passwordId}><span>密码</span></label><div className="account-password-field"><input id={passwordId} type={showPassword ? "text" : "password"} value={password} onChange={(event) => setPassword(event.target.value)} autoComplete={mode === "register" ? "new-password" : "current-password"} placeholder={mode === "register" ? "至少 8 个字符" : "输入密码"} maxLength={128} disabled={busy} required /><button type="button" aria-label={showPassword ? "隐藏密码" : "显示密码"} onClick={() => setShowPassword((show) => !show)}>{showPassword ? <EyeOff size={16} /> : <Eye size={16} />}</button></div>
        {mode === "register" && <label><span>确认密码</span><input type={showPassword ? "text" : "password"} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} autoComplete="new-password" placeholder="再次输入密码" maxLength={128} disabled={busy} required /></label>}
        {error && <div id={errorId} className="account-form-error" role="alert"><AlertCircle size={14} /><span>{error}</span></div>}
        <button className="account-submit" type="submit" disabled={busy}>{busy ? <><RefreshCw size={15} className="spin" /> 正在处理…</> : <>{mode === "login" ? "登录账户" : "注册并登录"}<ArrowRight size={15} /></>}</button>
      </form>
      <div className="account-guest-divider"><span />或<span /></div><button className="account-guest-login" type="button" disabled={busy} onClick={() => { void enterGuest(); }}><UserRound size={15} /> 游客登录 <span>共享体验账户</span></button>
      <p className="account-auth-note"><Cloud size={13} /><span>登录后保存主题、交易对、筛选、助手周期与图表周期。游客模式仅浏览，不保存设置。TradingView 内部画线与自定义指标不包含在此同步中。</span></p>
    </div>
  </div>, document.body);
}

export function AccountGate({ loading }: { loading: boolean }) {
  const [showForm, setShowForm] = useState(true);
  if (loading) return <div className="account-gate-loading" role="status"><div className="account-page-glyph"><span /><span /><span /></div><strong>正在检查账户会话</strong><small>准备你的市场观察台…</small></div>;
  if (showForm) return <AccountDialog initialMode="login" onClose={() => setShowForm(false)} returnFocusTo={null} presentation="page" />;
  return <>
    <div className="account-gate-backdrop"><div className="account-page-brand" aria-hidden="true"><div className="account-page-glyph"><span /><span /><span /></div><div><strong>ORBITAL</strong><small>MARKET INTELLIGENCE</small></div></div><div className="account-gate-copy"><span className="account-eyebrow">PRIVATE MARKET WORKSPACE</span><h1>登录后开始观察市场</h1><p>行情、合约分析和你的页面偏好都在同一个工作区中。游客可以浏览只读行情，不会保存设置。</p><button type="button" className="account-gate-cta" onClick={() => setShowForm(true)}><UserRound size={16} /> 登录 / 注册</button></div><div className="account-gate-footer">安全会话 · 个人偏好云端保存 · TradingView 内部画线由其自身管理</div></div>
  </>;
}
