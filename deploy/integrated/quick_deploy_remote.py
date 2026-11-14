#!/usr/bin/env python3
"""Remote half of quick_deploy.py; runs on 47.80.22.243 (Seoul)."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import re
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


ROOT = Path("/opt/trade-tools-integrated")
SERVICES = ("api", "market", "worker", "scheduler")
ALL_SERVICES = SERVICES + ("mysql", "redis")
NGINX_CONFIG = Path("/etc/nginx/snippets/tradetools-integrated.conf")


def command(args: list[str], *, env: dict[str, str] | None = None, output=None) -> None:
    subprocess.run(args, check=True, env=env, stdout=output, stderr=subprocess.STDOUT if output else None)


def inspect(service: str) -> dict:
    return json.loads(subprocess.check_output(["docker", "inspect", f"tradetools-integrated-{service}-1"]))[0]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compose(files: list[Path]) -> list[str]:
    args = [
        "docker",
        "compose",
        "--project-name",
        "tradetools-integrated",
        "--env-file",
        str(ROOT / "server.env"),
    ]
    for file in files:
        args.extend(("-f", str(file)))
    args.extend(("--profile", "pro"))
    return args


def activity_counts() -> dict[str, int]:
    code = """
import json, os
os.environ['RUN_SCHEDULER_IN_WEB'] = 'false'
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'riskon.settings')
import django; django.setup()
from django.db import connection
from mobile.models import TradingCommand
from positions.models import LimitOrder, Order
with connection.cursor() as cursor:
    cursor.execute('SET SESSION TRANSACTION READ ONLY')
print(json.dumps({
    'pending': TradingCommand.objects.filter(status='PENDING').count(),
    'running': TradingCommand.objects.filter(status='RUNNING').count(),
    'unknown': TradingCommand.objects.filter(status='UNKNOWN').count(),
    'openPositions': Order.objects.filter(status=0).count(),
    'pendingLimits': LimitOrder.objects.filter(status=0).count(),
}))
"""
    return json.loads(subprocess.check_output(["docker", "exec", "tradetools-integrated-api-1", "python", "-c", code]))


def extract(archive: Path, destination: Path) -> None:
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            path = PurePosixPath(member.name)
            if not member.isfile() and not member.isdir():
                raise RuntimeError(f"unsupported archive member: {member.name}")
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError(f"unsafe archive member: {member.name}")
        for member in source.getmembers():
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(target, member.mode & 0o777)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            payload = source.extractfile(member)
            if payload is None:
                raise RuntimeError(f"missing archive payload: {member.name}")
            with payload, target.open("wb") as output:
                shutil.copyfileobj(payload, output)
            os.chmod(target, member.mode & 0o777)


def main() -> int:
    incoming = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None
    if incoming is None or incoming.parent != (ROOT / "incoming").resolve():
        raise SystemExit("usage: quick_deploy_remote.py /opt/trade-tools-integrated/incoming/<release>")

    metadata = json.loads((incoming / "package.json").read_text())
    release_name = str(metadata["release"])
    if not re.fullmatch(r"integrated-quick-[0-9a-f]{7,40}", release_name):
        raise SystemExit(f"非法快速发布名称：{release_name}")
    if incoming.name != release_name:
        raise SystemExit("上传目录与发布名称不一致")
    release = ROOT / "releases" / release_name
    archive = incoming / f"{release_name}.tar.gz"
    if release.exists():
        raise SystemExit(f"发布目录已存在，拒绝覆盖：{release}")
    if sha256(archive) != metadata["sha256"]:
        raise SystemExit("归档 SHA-256 不匹配，拒绝发布")
    if (ROOT / "current").resolve() == release:
        raise SystemExit("目标版本已经是 current")

    lock_path = ROOT / "integrated-release.lock"
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = {service: inspect(service) for service in ALL_SERVICES}
        for service, item in before.items():
            if item["State"].get("Health", {}).get("Status") != "healthy":
                raise SystemExit(f"当前 {service} 不健康，停止快速发布")

        counts = activity_counts()
        if any(counts[key] for key in ("pending", "running", "unknown")):
            raise SystemExit(f"存在未收敛命令，停止快速发布：{json.dumps(counts, ensure_ascii=False)}")

        release.mkdir(mode=0o755)
        extract(archive, release)
        (release / "server.env").symlink_to(ROOT / "server.env")
        new_nginx = release / "deploy/integrated/nginx-location.conf"
        if sha256(new_nginx) != sha256(NGINX_CONFIG):
            raise SystemExit("Nginx 配置有变化，请使用完整发布流程")

        runtime = release / "compose.runtime.yaml"
        runtime.write_text(json.dumps({
            "services": {
                "mysql": {"image": before["mysql"]["Config"]["Image"]},
                "redis": {"image": before["redis"]["Config"]["Image"]},
            }
        }, indent=2) + "\n")
        files = [release / "compose.integrated.yaml", runtime]
        env = dict(os.environ, INTEGRATED_RELEASE=release_name)
        old_tag = before["api"]["Config"]["Image"]
        image = f"tradetools-integrated:{release_name}"
        log_path = incoming / "quick-deploy.log"
        with log_path.open("w") as log:
            if subprocess.run(["docker", "image", "inspect", image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                print(f"47.80.22.243（首尔服务器）：构建 {image}", flush=True)
                command([
                    "docker", "build", "--cache-from", old_tag,
                    "-f", str(release / "deploy/integrated/Dockerfile"),
                    "-t", image, str(release),
                ], output=log)
            else:
                print(f"47.80.22.243（首尔服务器）：复用已有镜像 {image}", flush=True)
            command(compose(files) + ["config", "--quiet"], env=env, output=log)
            checks = compose(files) + [
                "run", "--rm", "--no-deps", "-e", "RUN_SCHEDULER_IN_WEB=false",
                "--entrypoint", "sh", "api", "-c",
                "python manage.py check && "
                "python manage.py makemigrations --check --dry-run && "
                "python manage.py migrate --check",
            ]
            command(checks, env=env, output=log)

            old_files = [Path(item) for item in before["api"]["Config"].get("Labels", {}).get(
                "com.docker.compose.project.config_files", ""
            ).split(",") if item]
            if not old_files:
                raise SystemExit("无法找到旧 Compose 配置，停止快速发布")
            changed = False
            try:
                print("47.80.22.243（首尔服务器）：切换四个应用容器", flush=True)
                command(["docker", "stop", "--time", "120", "tradetools-integrated-worker-1", "tradetools-integrated-scheduler-1"], output=log)
                changed = True
                command(compose(files) + ["up", "-d", "--no-deps", "--no-build", "--pull", "never", "--wait", "--wait-timeout", "180", *SERVICES], env=env, output=log)
            except BaseException:
                if changed:
                    print("47.80.22.243（首尔服务器）：新服务未就绪，恢复旧应用容器；不恢复数据库", flush=True)
                    command(compose(old_files) + ["up", "-d", "--no-deps", "--no-build", "--pull", "never", "--wait", "--wait-timeout", "180", *SERVICES], output=log)
                raise

        next_link = ROOT / "current.quick-next"
        if next_link.exists() or next_link.is_symlink():
            next_link.unlink()
        next_link.symlink_to(release)
        os.replace(next_link, ROOT / "current")
        after = {service: inspect(service) for service in ALL_SERVICES}
        for service in SERVICES:
            if after[service]["State"].get("Health", {}).get("Status") != "healthy":
                raise SystemExit(f"新 {service} 未通过健康检查")
            if after[service]["Config"]["Image"] != image:
                raise SystemExit(f"新 {service} 镜像不一致")
        for service in ("mysql", "redis"):
            if after[service]["Id"] != before[service]["Id"]:
                raise SystemExit(f"基础设施容器被替换：{service}")
        health = subprocess.check_output([
            "curl", "--fail", "--silent", "--show-error", "--max-time", "20",
            "https://47.80.22.243/integrated/v1/health",
        ], text=True)
        result = {
            "target": "47.80.22.243（首尔服务器）",
            "release": release_name,
            "sourceCommit": metadata["sourceCommit"],
            "deployedAtUTC": datetime.now(timezone.utc).isoformat(),
            "databaseBackup": False,
            "isolatedTests": False,
            "activityBefore": counts,
            "health": json.loads(health),
            "infrastructureReplaced": False,
        }
        (incoming / "quick-deploy-result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
