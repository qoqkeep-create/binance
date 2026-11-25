import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AccountApiError, accountApi, acknowledgePreferencePatch, isPreferenceObject, mergePreferenceSettings, preferenceKeys, preferencePatch, type AccountSession, type AccountSettings, type AccountUser } from "./lib/account";

export type SyncStatus = "signed-out" | "loading" | "syncing" | "saved" | "guest" | "error";
interface AccountView {
  user: AccountUser | null;
  settings: AccountSettings;
  hydrating: boolean;
  authPending: boolean;
  syncStatus: SyncStatus;
  error: string | null;
}

interface AccountContextValue extends AccountView {
  login: (identifier: string, password: string) => Promise<void>;
  register: (details: { email: string; password: string; displayName?: string }) => Promise<void>;
  logout: () => Promise<void>;
  retrySync: () => void;
  updatePreference: (key: string, update: (current: unknown) => unknown, fallback?: unknown) => void;
}

const AccountContext = createContext<AccountContextValue | null>(null);
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const messageFor = (error: unknown) => error instanceof AccountApiError ? error.message : "账户服务连接失败，请检查网络后重试。";

/** Account state lives in memory; the short-lived access token is managed by accountApi. */
export function AccountProvider({ children }: { children: ReactNode }) {
  const [view, setView] = useState<AccountView>({ user: null, settings: {}, hydrating: true, authPending: false, syncStatus: "loading", error: null });
  const user = useRef<AccountUser | null>(null);
  const csrf = useRef<string | null>(null);
  const settings = useRef<AccountSettings>({});
  const dirty = useRef<AccountSettings>({});
  const version = useRef(0);
  const hydrated = useRef(false);
  const hydrating = useRef(true);
  const authPending = useRef(false);
  const sessionKnown = useRef(false);
  const generation = useRef(0);
  const controller = useRef(new AbortController());
  const timer = useRef<number | undefined>(undefined);
  const writing = useRef(false);
  const writePromise = useRef<Promise<void> | null>(null);
  const lastError = useRef<string | null>(null);
  const retrying = useRef(false);
  const disposed = useRef(false);
  const flushRef = useRef<(force?: boolean) => Promise<void>>(async () => undefined);
  const bootstrapRef = useRef<() => Promise<void>>(async () => undefined);

  const publish = useCallback((syncStatus: SyncStatus, error: string | null = null) => {
    if (disposed.current) return;
    lastError.current = error;
    setView({ user: user.current, settings: { ...settings.current }, hydrating: hydrating.current, authPending: authPending.current, syncStatus, error });
  }, []);

  function invalidateRequests() {
    generation.current += 1;
    controller.current.abort();
    controller.current = new AbortController();
    window.clearTimeout(timer.current);
    writing.current = false;
    writePromise.current = null;
    retrying.current = false;
    return generation.current;
  }

  function clearAccount() {
    user.current = null;
    csrf.current = null;
    settings.current = {};
    dirty.current = {};
    version.current = 0;
    hydrated.current = false;
    hydrating.current = false;
    sessionKnown.current = true;
    authPending.current = false;
  }

  function schedule(delay = 500) {
    window.clearTimeout(timer.current);
    if (user.current?.role === "user" && hydrated.current && !authPending.current) timer.current = window.setTimeout(() => { void flushRef.current(); }, delay);
  }

  async function loadSettings(expected: number) {
    hydrating.current = true;
    publish("loading");
    try {
      const response = await accountApi.settings(controller.current.signal);
      if (expected !== generation.current) return;
      version.current = response.version;
      settings.current = mergePreferenceSettings(response.settings, dirty.current);
      hydrated.current = true;
      hydrating.current = false;
      publish(user.current?.role === "guest" ? "guest" : Object.keys(dirty.current).length ? "syncing" : "saved");
      schedule();
    } catch (error) {
      if (expected !== generation.current) return;
      hydrating.current = false;
      if (error instanceof AccountApiError && error.status === 401) {
        invalidateRequests();
        clearAccount();
        publish("error", "登录已失效，请重新登录。");
      } else publish("error", messageFor(error));
    }
  }

  async function installSession(session: AccountSession, expected: number) {
    if (expected !== generation.current) return;
    sessionKnown.current = true;
    if (!session.user) {
      clearAccount();
      publish("signed-out");
      return;
    }
    user.current = session.user;
    csrf.current = session.csrfToken;
    settings.current = {};
    dirty.current = {};
    version.current = 0;
    hydrated.current = false;
    if (session.user.role === "guest") {
      // Visitor mode never hydrates or writes the shared preference row.
      hydrated.current = true;
      hydrating.current = false;
      publish("guest");
      return;
    }
    await loadSettings(expected);
  }

  bootstrapRef.current = async () => {
    const expected = invalidateRequests();
    hydrating.current = true;
    publish("loading");
    try {
      const session = await accountApi.session(controller.current.signal);
      await installSession(session, expected);
    } catch (error) {
      if (expected !== generation.current) return;
      hydrating.current = false;
      publish("error", messageFor(error));
    }
  };

  flushRef.current = (force = false) => {
    if (writing.current) return writePromise.current ?? Promise.resolve();
    if (user.current?.role !== "user" || !csrf.current || !hydrated.current || (authPending.current && !force) || !Object.keys(dirty.current).length) return Promise.resolve();
    const expected = generation.current;
    writing.current = true;
    publish("syncing");
    const operation = (async () => {
      let conflicts = 0;
      try {
      while (expected === generation.current && Object.keys(dirty.current).length) {
        const patch = { ...dirty.current };
        try {
          const response = await accountApi.saveSettings(patch, version.current, csrf.current!, controller.current.signal);
          if (expected !== generation.current) return;
          dirty.current = acknowledgePreferencePatch(dirty.current, patch);
          version.current = response.version;
          settings.current = mergePreferenceSettings(response.settings, dirty.current);
          publish(Object.keys(dirty.current).length ? "syncing" : "saved");
          conflicts = 0;
        } catch (error) {
          if (expected !== generation.current) return;
          if (error instanceof AccountApiError && error.status === 409 && conflicts++ < 3) {
            const latest = await accountApi.settings(controller.current.signal);
            if (expected !== generation.current) return;
            version.current = latest.version;
            settings.current = mergePreferenceSettings(latest.settings, dirty.current);
            publish("syncing");
            continue;
          }
          throw error;
        }
      }
    } catch (error) {
      if (expected !== generation.current) return;
      if (error instanceof AccountApiError && error.status === 401) {
        invalidateRequests();
        clearAccount();
        publish("error", "登录已失效，请重新登录。");
      } else publish("error", messageFor(error));
      } finally {
        if (expected === generation.current) { writing.current = false; writePromise.current = null; }
      }
    })();
    writePromise.current = operation;
    return operation;
  };

  useEffect(() => {
    disposed.current = false;
    void bootstrapRef.current();
    const flushWhenHidden = () => { if (document.visibilityState === "hidden") { window.clearTimeout(timer.current); void flushRef.current(); } };
    document.addEventListener("visibilitychange", flushWhenHidden);
    return () => {
      disposed.current = true;
      generation.current += 1;
      controller.current.abort();
      window.clearTimeout(timer.current);
      document.removeEventListener("visibilitychange", flushWhenHidden);
    };
  }, []);

  const login = useCallback(async (identifier: string, password: string) => {
    if (authPending.current) throw new Error("账户操作正在进行，请稍候。");
    const expected = invalidateRequests();
    authPending.current = true;
    publish(user.current ? "saved" : "signed-out");
    try {
      const response = await accountApi.login(identifier, password, csrf.current, controller.current.signal);
      await installSession(response, expected);
    } catch (error) {
      if (expected === generation.current) publish("error", messageFor(error));
      throw error;
    } finally {
      if (expected === generation.current) {
        authPending.current = false;
        publish(hydrated.current && user.current ? user.current.role === "guest" ? "guest" : Object.keys(dirty.current).length ? "syncing" : "saved" : user.current ? "error" : "signed-out", user.current && !hydrated.current ? lastError.current : null);
        schedule();
      }
    }
  }, [publish]);

  const register = useCallback(async (details: { email: string; password: string; displayName?: string }) => {
    if (authPending.current) throw new Error("账户操作正在进行，请稍候。");
    const expected = invalidateRequests();
    authPending.current = true;
    publish("signed-out");
    try {
      const response = await accountApi.register(details, csrf.current, controller.current.signal);
      await installSession(response, expected);
    } catch (error) {
      if (expected === generation.current) publish("error", messageFor(error));
      throw error;
    } finally {
      if (expected === generation.current) {
        authPending.current = false;
        publish(hydrated.current && user.current ? user.current.role === "guest" ? "guest" : Object.keys(dirty.current).length ? "syncing" : "saved" : user.current ? "error" : "signed-out", user.current && !hydrated.current ? lastError.current : null);
        schedule();
      }
    }
  }, [publish]);

  const logout = useCallback(async () => {
    if (authPending.current) return;
    const originalGeneration = generation.current;
    authPending.current = true;
    publish("syncing");
    // Finish the serialized settings write, including edits still in the debounce
    // window, before ending the session. A failed save stays visible for retry.
    await flushRef.current(true);
    if (originalGeneration !== generation.current) return;
    if (Object.keys(dirty.current).length) {
      authPending.current = false;
      publish("error", "设置尚未保存，退出未完成。请重试同步后再退出。");
      throw new Error("Pending account preferences were not saved");
    }
    const expected = invalidateRequests();
    try {
      await accountApi.logout(csrf.current, controller.current.signal);
      if (expected !== generation.current) return;
      clearAccount();
      authPending.current = false;
      publish("signed-out");
    } catch (error) {
      if (expected !== generation.current) return;
      authPending.current = false;
      if (error instanceof AccountApiError && error.status === 401) { clearAccount(); publish("signed-out"); }
      else { publish("error", "退出未完成，请检查网络后重试。"); throw error; }
    }
  }, [publish]);

  const retrySync = useCallback(() => {
    if (authPending.current || retrying.current || hydrating.current) return;
    if (!user.current || !sessionKnown.current) { void bootstrapRef.current(); return; }
    const expected = generation.current;
    retrying.current = true;
    void (async () => {
      try {
        const session = await accountApi.session(controller.current.signal);
        if (expected !== generation.current) return;
        if (!session.user || session.user.id !== user.current?.id) {
          const next = invalidateRequests();
          clearAccount();
          await installSession(session, next);
          return;
        }
        csrf.current = session.csrfToken;
        if (!hydrated.current) await loadSettings(expected);
        else if (Object.keys(dirty.current).length) await flushRef.current();
        else publish(user.current.role === "guest" ? "guest" : "saved");
      } catch (error) { if (expected === generation.current) publish("error", messageFor(error)); }
      finally { if (expected === generation.current) retrying.current = false; }
    })();
  }, [publish]);

  const updatePreference = useCallback((key: string, update: (current: unknown) => unknown, fallback?: unknown) => {
    if (!(preferenceKeys as readonly string[]).includes(key)) return;
    const next = update(settings.current[key]);
    if (next === undefined || same(next, settings.current[key])) return;
    const previous = key === "chart" && isPreferenceObject(fallback)
      ? { ...fallback, ...(isPreferenceObject(settings.current[key]) ? settings.current[key] : {}) } : settings.current[key];
    const patch = preferencePatch(key, previous, next);
    settings.current = { ...settings.current, [key]: next };
    if (user.current?.role === "user") dirty.current = mergePreferenceSettings(dirty.current, patch);
    publish(user.current ? user.current.role === "guest" ? "guest" : hydrated.current ? Object.keys(dirty.current).length ? "syncing" : "saved" : "loading" : "signed-out");
    schedule();
  }, [publish]);

  const value = useMemo(() => ({ ...view, login, register, logout, retrySync, updatePreference }), [view, login, register, logout, retrySync, updatePreference]);
  return <AccountContext.Provider value={value}>{children}</AccountContext.Provider>;
}

export function useAccount() {
  const context = useContext(AccountContext);
  if (!context) throw new Error("useAccount must be used within AccountProvider");
  return context;
}

/** Missing/invalid cloud values use the fallback without writing it to the server. */
export function usePreference<T>(key: string, fallback: T, validate?: (value: unknown) => value is T): [T, (next: T | ((current: T) => T)) => void] {
  const { settings, updatePreference } = useAccount();
  const valid = (value: unknown): value is T => value !== undefined && (!validate || validate(value));
  const stored = key === "chart" && isPreferenceObject(fallback) && isPreferenceObject(settings[key]) ? { ...fallback, ...settings[key] } : settings[key];
  const value = valid(stored) ? stored : fallback;
  const inputs = useRef({ fallback, validate });
  inputs.current = { fallback, validate };
  const setValue = useCallback((next: T | ((current: T) => T)) => {
    updatePreference(key, (stored) => {
      const { fallback, validate } = inputs.current;
      const effective = key === "chart" && isPreferenceObject(fallback) && isPreferenceObject(stored) ? { ...fallback, ...stored } : stored;
      const current = effective !== undefined && (!validate || validate(effective)) ? effective as T : fallback;
      const result = typeof next === "function" ? (next as (value: T) => T)(current) : next;
      return same(result, current) ? stored : result;
    }, inputs.current.fallback);
  }, [key, updatePreference]);
  return [value, setValue];
}
