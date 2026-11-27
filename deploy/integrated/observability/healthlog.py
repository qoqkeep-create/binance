#!/usr/bin/env python3
"""轻量观测：每分钟采集主机/容器/health 关键指标，CSV 落盘，每日汇总长期保留。

用法：
  healthlog.py collect        采一个样本（cron 每分钟，flock 防重叠）
  healthlog.py backfill       从 sysstat(sar) 回填历史主机指标 + journal OOM 事件
  healthlog.py report [N|all] 当前快照 + 近 N 天汇总（默认 7）+ 每日/每月趋势

数据目录：/opt/trade-tools-integrated/observability/data（可用 TRADETOOLS_OBS_DIR 覆盖）
  metrics-YYYYMM.csv  每分钟原始样本，保留 3 个月，更早 gzip 保留 12 个月
  daily.csv           每日汇总，永久保留（长期趋势来源）
  events.log          重启 / OOM / health 异常 / 容器状态变化，1MB 轮转
"""
import csv
import glob
import gzip
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Asia/Shanghai")
BASE = Path(os.environ.get("TRADETOOLS_OBS_DIR", "/opt/trade-tools-integrated/observability"))
DATA = BASE / "data"
SERVICES = ["api", "market", "worker", "scheduler", "mysql", "redis"]
FULL = {s: f"tradetools-integrated-{s}-1" for s in SERVICES}
HEALTH_URL = "https://127.0.0.1/integrated/v1/health"
NCPU = os.cpu_count() or 1
RAW_KEEP_MONTHS = 3
GZ_KEEP_MONTHS = 12
STATS_EVERY_MIN = 5  # docker stats 单次约 2s，每 5 分钟采一次容器 CPU/内存

FIELDS = (
    ["ts", "load1", "load5", "load15", "cpu_busy", "cpu_iowait",
     "mem_avail_mb", "mem_total_mb", "swap_used_mb", "disk_pct", "disk_avail_gb",
     "health_code", "health_ms", "health_ok", "nginx"]
    + [f"{s}_{k}" for s in SERVICES for k in ("cpu", "mem")]
    + ["states"]
)
DAILY_FIELDS = ["date", "samples", "load1_avg", "load1_max", "load5_max",
                "iowait_avg", "iowait_max", "mem_avail_min_mb", "swap_max_mb",
                "disk_pct_max", "health_bad", "health_ms_max", "down_min",
                "restarts", "ooms"]
TIME_RE = re.compile(r"^\d{2}:\d{2}:\d{2}$")


def run(cmd, timeout, env=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return r.stdout
    except Exception:
        return ""


def sh(ts):
    return datetime.fromtimestamp(float(ts), TZ)


def month_key(dt):
    return dt.strftime("%Y%m")


def month_age(key):
    now = datetime.now(TZ)
    y, m = int(key[:4]), int(key[4:6])
    return (now.year - y) * 12 + now.month - m


def fnum(row, key):
    v = row.get(key, "")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def avg(vals):
    return sum(vals) / len(vals) if vals else None


def fmt(v, nd=1):
    return "-" if v is None else f"{v:.{nd}f}"


def load_state():
    try:
        return json.loads((DATA / "state.json").read_text())
    except Exception:
        return {}


def save_state(st):
    tmp = DATA / "state.json.tmp"
    tmp.write_text(json.dumps(st))
    tmp.replace(DATA / "state.json")


def iter_raw():
    for f in sorted(DATA.glob("metrics-*.csv")):
        with open(f, newline="") as fh:
            for row in csv.DictReader(fh):
                yield row


def last_ts_of(f):
    with open(f, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 4096))
        lines = fh.read().decode().splitlines()
    for line in reversed(lines):
        if line.strip():
            try:
                return int(line.split(",", 1)[0])
            except ValueError:
                return 0
    return 0


def append_rows(rows):
    by_month = {}
    for r in rows:
        by_month.setdefault(month_key(sh(r["ts"])), []).append(r)
    for mk, rs in by_month.items():
        f = DATA / f"metrics-{mk}.csv"
        rs.sort(key=lambda r: int(r["ts"]))
        if f.exists() and int(rs[0]["ts"]) < last_ts_of(f):
            with open(f, newline="") as fh:
                existing = list(csv.DictReader(fh))
            merged = sorted(existing + rs, key=lambda r: int(r["ts"]))
            with open(f, "w", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=FIELDS)
                w.writeheader()
                w.writerows(merged)
        else:
            new = not f.exists()
            with open(f, "a", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=FIELDS)
                if new:
                    w.writeheader()
                w.writerows(rs)


def log_events(events):
    if not events:
        return
    with open(DATA / "events.log", "a") as fh:
        for ts, kind, detail in events:
            fh.write(f"{sh(ts).strftime('%Y-%m-%dT%H:%M:%S')}\t{kind}\t{detail}\n")


def read_events():
    f = DATA / "events.log"
    if not f.exists():
        return []
    out = []
    for line in f.read_text().splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            try:
                ts = datetime.strptime(parts[0], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=TZ).timestamp()
                out.append((ts, parts[1], parts[2]))
            except ValueError:
                pass
    return out


# ---------- 采集 ----------

def proc_metrics(st, ts):
    load = Path("/proc/loadavg").read_text().split()
    mem = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, v = line.split(":", 1)
        mem[k] = int(v.split()[0])
    jif = [int(x) for x in Path("/proc/stat").read_text().splitlines()[0].split()[1:9]]
    busy = iowait = ""
    prev = st.get("jiffies")
    if prev and len(prev) == 8:
        dtotal = sum(jif) - sum(prev)
        if dtotal > 0:
            iowait = round((jif[4] - prev[4]) / dtotal * 100, 1)
            busy = round((dtotal - (jif[3] - prev[3]) - (jif[4] - prev[4])) / dtotal * 100, 1)
    st["jiffies"] = jif
    vfs = os.statvfs("/")
    used = (vfs.f_blocks - vfs.f_bfree) * vfs.f_frsize
    avail = vfs.f_bavail * vfs.f_frsize
    return {
        "load1": load[0], "load5": load[1], "load15": load[2],
        "cpu_busy": busy, "cpu_iowait": iowait,
        "mem_avail_mb": round(mem["MemAvailable"] / 1024, 1),
        "mem_total_mb": round(mem["MemTotal"] / 1024, 1),
        "swap_used_mb": round((mem["SwapTotal"] - mem["SwapFree"]) / 1024, 1),
        "disk_pct": round(used / (used + avail) * 100, 1) if used + avail else "",
        "disk_avail_gb": round(avail / 2 ** 30, 2),
    }


def check_health():
    t0 = time.monotonic()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urlopen(Request(HEALTH_URL), timeout=5, context=ctx) as r:
            code, body = r.status, r.read(4096)
    except HTTPError as e:
        code, body = e.code, b""
    except Exception:
        code, body = 0, b""
    ms = round((time.monotonic() - t0) * 1000, 1)
    ok = code == 200
    try:
        j = json.loads(body)
        ok = ok and j.get("status") == "ok" and all(v is True for v in j.get("checks", {}).values())
    except Exception:
        ok = False
    return code, ms, 1 if ok else 0


def docker_states():
    out = run(["docker", "inspect", "--format",
               "{{.Name}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.StartedAt}}"]
              + [FULL[s] for s in SERVICES], 10)
    states, started = {}, {}
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) != 3:
            continue
        name = parts[0].lstrip("/")
        for s in SERVICES:
            if name == FULL[s]:
                states[s], started[s] = parts[1], parts[2]
    for s in SERVICES:
        states.setdefault(s, "missing")
        started.setdefault(s, "")
    return states, started


def docker_stats():
    out = run(["docker", "stats", "--no-stream", "--format",
               "{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}"], 20)
    vals = {}
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) != 3:
            continue
        name = parts[0].strip()
        for s in SERVICES:
            if name == FULL[s]:
                try:
                    vals[f"{s}_cpu"] = round(float(parts[1].rstrip("%")), 1)
                    vals[f"{s}_mem"] = round(float(parts[2].rstrip("%")), 1)
                except ValueError:
                    pass
    return vals


def scan_oom(since_ts):
    out = run(["journalctl", "-k", "--since", f"@{int(since_ts)}", "--no-pager", "-o", "short-iso"], 10)
    lines = out.splitlines()

    def parse(line):
        m = re.match(r"^(\S+)\s", line)
        if not m:
            return None
        try:
            ts = datetime.fromisoformat(m.group(1)).timestamp()
        except ValueError:
            return None
        cid = re.search(r"docker-([0-9a-f]{12,64})\.scope", line)
        task = re.search(r"task=(\w+)", line) or re.search(r"Killed process \d+ \((\w+)\)", line)
        return ts, cid.group(1) if cid else "", task.group(1) if task else "?"

    hits, captured = [], set()
    for line in lines:
        if "oom-kill:" in line and (h := parse(line)):
            hits.append(h)
            captured.add(int(h[0]))
    for line in lines:
        if "Killed process" in line and (h := parse(line)) and int(h[0]) not in captured:
            hits.append(h)
    if not hits:
        return []
    idmap = {}
    out = run(["docker", "ps", "-a", "--no-trunc", "--format", "{{.ID}}|{{.Names}}"], 10)
    for line in out.splitlines():
        parts = line.split("|", 1)
        if len(parts) == 2:
            idmap[parts[0]] = parts[1].strip()
    events, seen = [], set()
    for ts, cid, task in hits:
        name = idmap.get(cid, "")
        for s in SERVICES:
            if name == FULL[s]:
                name = s
                break
        detail = f"{name or cid[:12] or '宿主'} OOM 杀进程 task={task}"
        key = (int(ts), detail)
        if key not in seen:
            seen.add(key)
            events.append((ts, "oom", detail))
    return events


def abnormal(row):
    if row.get("health_ok") == "0":
        return True
    if row.get("nginx") not in ("", "active"):
        return True
    for kv in (row.get("states") or "").split(";"):
        if kv and kv.split("=", 1)[-1] not in ("healthy", "none", ""):
            return True
    return False


def rollup_day(day, events_by_day):
    rows = [r for r in iter_raw() if sh(r["ts"]).strftime("%Y-%m-%d") == day]
    if not rows:
        return None
    load1 = [v for r in rows if (v := fnum(r, "load1")) is not None]
    load5 = [v for r in rows if (v := fnum(r, "load5")) is not None]
    io = [v for r in rows if (v := fnum(r, "cpu_iowait")) is not None]
    mem = [v for r in rows if (v := fnum(r, "mem_avail_mb")) is not None]
    swap = [v for r in rows if (v := fnum(r, "swap_used_mb")) is not None]
    disk = [v for r in rows if (v := fnum(r, "disk_pct")) is not None]
    hms = [v for r in rows if (v := fnum(r, "health_ms")) is not None and r.get("health_code") not in ("", None)]
    ev = events_by_day.get(day, [])
    return {
        "date": day, "samples": len(rows),
        "load1_avg": fmt(avg(load1), 2), "load1_max": fmt(max(load1) if load1 else None, 2),
        "load5_max": fmt(max(load5) if load5 else None, 2),
        "iowait_avg": fmt(avg(io)), "iowait_max": fmt(max(io) if io else None),
        "mem_avail_min_mb": fmt(min(mem) if mem else None, 0),
        "swap_max_mb": fmt(max(swap) if swap else None, 0),
        "disk_pct_max": fmt(max(disk) if disk else None),
        "health_bad": sum(1 for r in rows if r.get("health_ok") == "0"),
        "health_ms_max": fmt(max(hms) if hms else None, 0),
        "down_min": sum(1 for r in rows if abnormal(r)),
        "restarts": sum(1 for _, k, _ in ev if k == "restart"),
        "ooms": sum(1 for _, k, _ in ev if k == "oom"),
    }


def append_daily(entry):
    f = DATA / "daily.csv"
    existing = set()
    if f.exists():
        with open(f, newline="") as fh:
            existing = {r["date"] for r in csv.DictReader(fh)}
    if entry["date"] in existing:
        return
    new = not f.exists()
    with open(f, "a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=DAILY_FIELDS)
        if new:
            w.writeheader()
        w.writerow(entry)


def do_rollup(st):
    events_by_day = {}
    for ts, kind, detail in read_events():
        events_by_day.setdefault(sh(ts).strftime("%Y-%m-%d"), []).append((ts, kind, detail))
    yesterday = (datetime.now(TZ) - timedelta(days=1)).strftime("%Y-%m-%d")
    day = st.get("rolled_day")
    if not day:
        st["rolled_day"] = datetime.now(TZ).strftime("%Y-%m-%d")
        return
    d = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=TZ)
    end = datetime.strptime(yesterday, "%Y-%m-%d").replace(tzinfo=TZ)
    while d < end:
        d = d + timedelta(days=1)
        key = d.strftime("%Y-%m-%d")
        entry = rollup_day(key, events_by_day)
        if entry:
            append_daily(entry)
    st["rolled_day"] = yesterday


def retention():
    for f in DATA.glob("metrics-*.csv"):
        if month_age(f.stem[-6:]) >= RAW_KEEP_MONTHS:
            with open(f, "rb") as src, gzip.open(str(f) + ".gz", "wb") as dst:
                shutil.copyfileobj(src, dst)
            f.unlink()
    for f in DATA.glob("metrics-*.csv.gz"):
        if month_age(f.name[8:14]) >= GZ_KEEP_MONTHS:
            f.unlink()
    ev = DATA / "events.log"
    if ev.exists() and ev.stat().st_size > 1_000_000:
        ev.replace(DATA / "events.log.1")
    err = BASE / "collect.err"
    if err.exists() and err.stat().st_size > 256_000:
        err.write_text("")


def collect():
    DATA.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    st = load_state()
    row = {"ts": ts}
    row.update(proc_metrics(st, ts))
    row["nginx"] = run(["systemctl", "is-active", "nginx"], 5).strip() or "unknown"
    states, started = docker_states()
    row["states"] = ";".join(f"{s}={states[s]}" for s in SERVICES)
    if datetime.now(TZ).minute % STATS_EVERY_MIN == 0 or not st.get("last_ts"):
        row.update(docker_stats())
    code, ms, ok = check_health()
    row["health_code"], row["health_ms"], row["health_ok"] = code, ms, ok

    events = []
    prev_states = st.get("states", {})
    prev_started = st.get("started", {})
    for s in SERVICES:
        if prev_started.get(s) and started[s] and prev_started[s] != started[s]:
            events.append((ts, "restart", f"{s} 容器重启（{prev_started[s][:19]} → {started[s][:19]}）"))
        if prev_states.get(s) and prev_states[s] != states[s]:
            events.append((ts, "state", f"{s} {prev_states[s]} → {states[s]}"))
    if st.get("health_ok") is not None and st["health_ok"] != ok:
        events.append((ts, "health", "health 异常" if not ok else "health 恢复"))
    if st.get("nginx") and st["nginx"] != row["nginx"]:
        events.append((ts, "nginx", f"nginx {st['nginx']} → {row['nginx']}"))
    if st.get("last_ts"):
        events.extend(scan_oom(st["last_ts"]))
    log_events(events)

    append_rows([row])
    st.update({"last_ts": ts, "states": states, "started": started,
               "health_ok": ok, "nginx": row["nginx"]})
    do_rollup(st)
    retention()
    save_state(st)
    print(f"ok ts={ts} load1={row['load1']} health={code}/{ms}ms")


# ---------- sar 回填 ----------

def parse_sar(text, keycols):
    lines = text.splitlines()
    day = None
    for line in lines:
        if line.startswith("Linux"):
            m = re.search(r"\d{4}-\d{2}-\d{2}", line)
            if m:
                day = m.group(0)
            break
    idx, start = None, 0
    for i, line in enumerate(lines):
        parts = line.split()
        if parts and TIME_RE.match(parts[0]) and any(k in parts for k in keycols):
            idx = {name: j for j, name in enumerate(parts)}
            start = i + 1
            break
    if idx is None or day is None:
        return day, {}
    out = {}
    for line in lines[start:]:
        parts = line.split()
        if not parts or not TIME_RE.match(parts[0]):
            continue
        out[parts[0]] = parts
    return day, (idx, out)


def sar_rows(sa_file):
    env = dict(os.environ, S_TIME_FORMAT="ISO", LC_ALL="C")
    day, q = parse_sar(run(["sar", "-q", "-f", sa_file], 20, env), ["ldavg-1"])
    _, u = parse_sar(run(["sar", "-u", "-f", sa_file], 20, env), ["%iowait"])
    _, r = parse_sar(run(["sar", "-r", "-f", sa_file], 20, env), ["kbavail"])
    _, s = parse_sar(run(["sar", "-S", "-f", sa_file], 20, env), ["kbswpused"])
    if not day or not q:
        return []
    qi, qrows = q
    rows = []
    for t, parts in qrows.items():
        try:
            ts = datetime.strptime(f"{day} {t}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=TZ).timestamp()
        except ValueError:
            continue
        row = {"ts": int(ts)}
        try:
            row["load1"] = parts[qi["ldavg-1"]]
            row["load5"] = parts[qi["ldavg-5"]]
            row["load15"] = parts[qi["ldavg-15"]]
        except (IndexError, KeyError):
            pass
        if u:
            ui, urows = u
            up = urows.get(t)
            if up and up[ui["CPU"]] == "all":
                idle = float(up[ui["%idle"]])
                io = float(up[ui["%iowait"]])
                row["cpu_iowait"] = up[ui["%iowait"]]
                row["cpu_busy"] = round(100 - idle - io, 1)
        if r:
            ri, rrows = r
            rp = rrows.get(t)
            if rp:
                try:
                    row["mem_avail_mb"] = round(int(rp[ri["kbavail"]]) / 1024, 1)
                    used, pct = int(rp[ri["kbmemused"]]), float(rp[ri["%memused"]])
                    row["mem_total_mb"] = round(used / pct * 100 / 1024, 1) if pct else ""
                except (IndexError, KeyError, ValueError):
                    pass
        if s:
            si, srows = s
            sp = srows.get(t)
            if sp:
                try:
                    row["swap_used_mb"] = round(int(sp[si["kbswpused"]]) / 1024, 1)
                except (IndexError, KeyError, ValueError):
                    pass
        rows.append(row)
    return rows


def backfill():
    DATA.mkdir(parents=True, exist_ok=True)
    existing = {int(r["ts"]) for r in iter_raw() if r.get("ts")}
    added = 0
    earliest = None
    for sa in sorted(glob.glob("/var/log/sysstat/sa[0-9][0-9]")):
        rows = [r for r in sar_rows(sa) if r["ts"] not in existing]
        if rows:
            append_rows(rows)
            added += len(rows)
            earliest = min(earliest or rows[0]["ts"], rows[0]["ts"])
    st = load_state()
    oom_since = time.time() - 22 * 86400
    known = {(int(ts), d) for ts, k, d in read_events() if k == "oom"}
    log_events([e for e in scan_oom(oom_since) if (int(e[0]), e[2]) not in known])
    if earliest:
        st["rolled_day"] = (sh(earliest) - timedelta(days=1)).strftime("%Y-%m-%d")
        do_rollup(st)
        save_state(st)
    print(f"backfill 新增 {added} 行历史样本")


# ---------- 报表 ----------

def latest_rows(n=8):
    files = sorted(DATA.glob("metrics-*.csv"))
    if not files:
        return []
    with open(files[-1], newline="") as fh:
        rows = list(csv.DictReader(fh))
    return rows[-n:]


def snapshot():
    rows = latest_rows()
    if not rows:
        print("暂无样本")
        return
    last = rows[-1]
    t = sh(last["ts"]).strftime("%Y-%m-%d %H:%M:%S")
    print(f"== 当前快照（{t}，{NCPU} 核）==")
    print(f"负载 1/5/15 分钟: {last['load1']} / {last['load5']} / {last['load15']}"
          f"    CPU 忙 {fmt(fnum(last,'cpu_busy'))}%  iowait {fmt(fnum(last,'cpu_iowait'))}%")
    print(f"内存可用: {fmt(fnum(last,'mem_avail_mb'),0)} / {fmt(fnum(last,'mem_total_mb'),0)} MiB"
          f"    swap 已用 {fmt(fnum(last,'swap_used_mb'),0)} MiB")
    print(f"磁盘: {fmt(fnum(last,'disk_pct'))}%  剩余 {fmt(fnum(last,'disk_avail_gb'),1)} GiB")
    hc, hms, ok = last.get("health_code", ""), last.get("health_ms", ""), last.get("health_ok", "")
    print(f"health: HTTP {hc or '-'}  {hms or '-'}ms  {'正常' if ok == '1' else '异常' if ok == '0' else '-'}"
          f"    nginx: {last.get('nginx') or '-'}")
    warns = []
    for s in SERVICES:
        cpu = mem = state = None
        for r in reversed(rows):
            if cpu is None and r.get(f"{s}_cpu"):
                cpu = r[f"{s}_cpu"]
            if mem is None and r.get(f"{s}_mem"):
                mem = r[f"{s}_mem"]
        for kv in (last.get("states") or "").split(";"):
            if kv.startswith(s + "="):
                state = kv.split("=", 1)[1]
        print(f"  {s:<10} CPU {cpu or '-':>6}%  内存 {mem or '-':>6}%（限额占比）  {state or '-'}")
        if mem is not None and float(mem) >= 85:
            warns.append(f"{s} 内存达限额 {mem}%")
        if state not in (None, "healthy", "none", ""):
            warns.append(f"{s} 状态 {state}")
    if fnum(last, "disk_pct") is not None and fnum(last, "disk_pct") >= 85:
        warns.append(f"磁盘 {last['disk_pct']}%")
    if fnum(last, "load1") is not None and fnum(last, "load1") > NCPU * 1.5:
        warns.append(f"load1 {last['load1']} 超 {NCPU} 核×1.5")
    if fnum(last, "cpu_iowait") is not None and fnum(last, "cpu_iowait") >= 30:
        warns.append(f"iowait {last['cpu_iowait']}%")
    if ok == "0":
        warns.append("health 异常")
    print("告警: " + ("；".join(warns) if warns else "无"))


def window_raw(cutoff):
    vals = {k: [] for k in ("load1", "load5", "cpu_busy", "cpu_iowait", "mem_avail_mb", "swap_used_mb", "disk_pct", "health_ms")}
    n = bad = down = 0
    svc_bad = {s: 0 for s in SERVICES}
    svc_mem_hi = {s: 0 for s in SERVICES}
    peak = (None, -1.0)
    first = last = None
    for r in iter_raw():
        try:
            ts = int(r["ts"])
        except (KeyError, ValueError):
            continue
        if ts < cutoff:
            continue
        n += 1
        first = ts if first is None else min(first, ts)
        last = ts if last is None else max(last, ts)
        for k in vals:
            v = fnum(r, k)
            if v is not None and not (k == "health_ms" and r.get("health_code") in ("", None)):
                vals[k].append(v)
        l1 = fnum(r, "load1")
        if l1 is not None and l1 > peak[1]:
            peak = (ts, l1)
        if r.get("health_ok") == "0":
            bad += 1
        if abnormal(r):
            down += 1
        for kv in (r.get("states") or "").split(";"):
            if "=" in kv:
                s, st = kv.split("=", 1)
                if s in svc_bad and st not in ("healthy", "none", ""):
                    svc_bad[s] += 1
        for s in SERVICES:
            v = fnum(r, f"{s}_mem")
            if v is not None and v >= 85:
                svc_mem_hi[s] += 1
    return dict(n=n, first=first, last=last, vals=vals, bad=bad, down=down,
                svc_bad=svc_bad, svc_mem_hi=svc_mem_hi, peak=peak)


def print_window(days):
    cutoff = time.time() - days * 86400
    w = window_raw(cutoff)
    if not w["n"]:
        print(f"\n== 近 {days} 天汇总 ==\n暂无样本")
        return
    span = f"{sh(w['first']).strftime('%m-%d %H:%M')} ~ {sh(w['last']).strftime('%m-%d %H:%M')}"
    print(f"\n== 近 {days} 天汇总（{span}，{w['n']} 个样本）==")
    v = w["vals"]
    pk = f"，峰值 {w['peak'][1]:.2f} @ {sh(w['peak'][0]).strftime('%m-%d %H:%M')}" if w["peak"][0] else ""
    print(f"load1 均值 {fmt(avg(v['load1']),2)}{pk}    load5 峰值 {fmt(max(v['load5']) if v['load5'] else None,2)}")
    print(f"iowait 均值 {fmt(avg(v['cpu_iowait']))}%  峰值 {fmt(max(v['cpu_iowait']) if v['cpu_iowait'] else None)}%"
          f"    CPU忙 均值 {fmt(avg(v['cpu_busy']))}%")
    print(f"内存可用 均值 {fmt(avg(v['mem_avail_mb']),0)}  最低 {fmt(min(v['mem_avail_mb']) if v['mem_avail_mb'] else None,0)} MiB"
          f"    swap 峰值 {fmt(max(v['swap_used_mb']) if v['swap_used_mb'] else None,0)} MiB")
    if v["disk_pct"]:
        print(f"磁盘 {v['disk_pct'][0]:.1f}% → {v['disk_pct'][-1]:.1f}%（峰值 {max(v['disk_pct']):.1f}%）")
    hn = len(v["health_ms"])
    print(f"health 检查 {hn} 次，异常 {w['bad']} 次，延迟均值 {fmt(avg(v['health_ms']),0)}ms"
          f"  峰值 {fmt(max(v['health_ms']) if v['health_ms'] else None,0)}ms")
    print(f"异常分钟数（health/nginx/容器任一不正常）: {w['down']}")
    for s in SERVICES:
        extra = f"，内存≥85% 限额 {w['svc_mem_hi'][s]} 次" if w["svc_mem_hi"][s] else ""
        if w["svc_bad"][s] or extra:
            print(f"  {s}: 状态异常 {w['svc_bad'][s]} 分钟{extra}")
    evs = [e for e in read_events() if e[0] >= cutoff]
    if evs:
        print(f"事件 {len(evs)} 条:")
        for ts, kind, detail in evs[-12:]:
            print(f"  {sh(ts).strftime('%m-%d %H:%M')} [{kind}] {detail}")
        if len(evs) > 12:
            print(f"  …（仅显示最近 12 条，共 {len(evs)} 条）")
    else:
        print("事件: 无重启/OOM/health 异常记录")


def print_daily(days):
    f = DATA / "daily.csv"
    if not f.exists():
        return
    with open(f, newline="") as fh:
        rows = list(csv.DictReader(fh))
    cutoff = (datetime.now(TZ) - timedelta(days=days - 1)).strftime("%Y-%m-%d")
    rows = [r for r in rows if r["date"] >= cutoff]
    today = datetime.now(TZ).strftime("%Y-%m-%d")
    if not any(r["date"] == today for r in rows):
        ev_by_day = {}
        for ts, kind, detail in read_events():
            ev_by_day.setdefault(sh(ts).strftime("%Y-%m-%d"), []).append((ts, kind, detail))
        entry = rollup_day(today, ev_by_day)
        if entry:
            entry["date"] = today + "*"
            rows.append(entry)
    if not rows:
        return
    print(f"\n== 每日趋势（{len(rows)} 天，* 为今日截至当前）==")
    print(f"{'日期':<12}{'样本':>6}{'load1均/峰':>12}{'io均/峰%':>11}{'内存最低':>9}{'磁盘峰%':>8}{'health异常':>9}{'异常分':>7}{'重启':>5}{'OOM':>5}")
    for r in rows:
        print(f"{r['date']:<12}{r['samples']:>6}{r['load1_avg']+'/'+r['load1_max']:>12}"
              f"{r['iowait_avg']+'/'+r['iowait_max']:>11}{r['mem_avail_min_mb']:>9}{r['disk_pct_max']:>8}"
              f"{r['health_bad']:>9}{r['down_min']:>7}{r['restarts']:>5}{r['ooms']:>5}")


def print_all():
    f = DATA / "daily.csv"
    if not f.exists():
        print("\n== 长期趋势 ==\n暂无每日汇总")
        return
    with open(f, newline="") as fh:
        rows = list(csv.DictReader(fh))
    months = {}
    for r in rows:
        months.setdefault(r["date"][:7], []).append(r)
    print(f"\n== 长期趋势（按月，{len(rows)} 天）==")
    print(f"{'月份':<9}{'天数':>5}{'load1均/峰':>12}{'io峰%':>7}{'内存最低':>9}{'磁盘峰%':>8}{'health异常':>9}{'异常分':>7}{'重启':>5}{'OOM':>5}")
    for mk in sorted(months):
        rs = months[mk]
        l_avg = avg([float(r["load1_avg"]) for r in rs if r["load1_avg"] not in ("", "-")])
        l_max = max((float(r["load1_max"]) for r in rs if r["load1_max"] not in ("", "-")), default=None)
        io = max((float(r["iowait_max"]) for r in rs if r["iowait_max"] not in ("", "-")), default=None)
        mem = min((float(r["mem_avail_min_mb"]) for r in rs if r["mem_avail_min_mb"] not in ("", "-")), default=None)
        disk = max((float(r["disk_pct_max"]) for r in rs if r["disk_pct_max"] not in ("", "-")), default=None)
        print(f"{mk:<9}{len(rs):>5}{fmt(l_avg,2)+'/'+fmt(l_max,2):>12}{fmt(io):>7}{fmt(mem,0):>9}{fmt(disk):>8}"
              f"{sum(int(r['health_bad'] or 0) for r in rs):>9}{sum(int(r['down_min'] or 0) for r in rs):>7}"
              f"{sum(int(r['restarts'] or 0) for r in rs):>5}{sum(int(r['ooms'] or 0) for r in rs):>5}")
    evs = read_events()
    if evs:
        print(f"历史事件共 {len(evs)} 条，最近 10 条:")
        for ts, kind, detail in evs[-10:]:
            print(f"  {sh(ts).strftime('%Y-%m-%d %H:%M')} [{kind}] {detail}")


def report(arg):
    snapshot()
    if arg == "all":
        print_all()
        return
    try:
        days = max(1, int(arg))
    except ValueError:
        days = 7
    if days <= 31:
        print_window(days)
        print_daily(days)
    else:
        print_all()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"
    if cmd == "collect":
        collect()
    elif cmd == "backfill":
        backfill()
    elif cmd == "report":
        report(sys.argv[2] if len(sys.argv) > 2 else "7")
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()