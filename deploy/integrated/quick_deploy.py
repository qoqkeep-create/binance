#!/usr/bin/env python3
"""Fast, application-only deployment for the integrated backend.

This path deliberately does not dump the production database, run migrations,
bootstrap accounts, or start MySQL/Redis.  Use the full release workflow for
schema changes or changes that need isolated integration coverage.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


DEFAULT_HOST = "root@47.80.22.243"
DEFAULT_SSH_KEY = "/Users/apple/.ssh/trade_tool_seoul_ed25519"
DEFAULT_REMOTE_ROOT = "/opt/trade-tools-integrated"
INCLUDED_PATHS = (
    "server",
    "deploy/integrated",
    "compose.integrated.yaml",
    ".dockerignore",
)


def run(command: list[str], *, cwd: Path | None = None, capture: bool = False) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout if capture else ""


def archive_source(repo: Path, staging: Path) -> tuple[Path, dict[str, object]]:
    staging.mkdir(parents=True, exist_ok=True)
    commit = run(["git", "rev-parse", "HEAD"], cwd=repo, capture=True).strip()
    if run(["git", "status", "--porcelain"], cwd=repo, capture=True).strip():
        raise SystemExit("工作区有未提交改动；请先提交后再执行快速部署")

    short = commit[:7]
    release = f"integrated-quick-{short}"
    raw = subprocess.check_output(
        ["git", "archive", "--format=tar", commit, *INCLUDED_PATHS],
        cwd=repo,
    )
    archive = staging / f"{release}.tar.gz"
    with tarfile.open(fileobj=io.BytesIO(raw)) as source:
        members = source.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if not member.isfile() and not member.isdir():
                raise SystemExit(f"源码归档包含不支持的条目：{member.name}")
            if path.is_absolute() or ".." in path.parts:
                raise SystemExit(f"源码归档路径非法：{member.name}")
        with tarfile.open(archive, "w:gz") as target:
            for member in members:
                payload = source.extractfile(member) if member.isfile() else None
                if payload is None:
                    target.addfile(member)
                else:
                    target.addfile(member, payload)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    metadata = {
        "release": release,
        "sourceCommit": commit,
        "scope": "fast-integrated-backend",
        "sha256": digest,
        "archiveBytes": archive.stat().st_size,
        "includedPaths": list(INCLUDED_PATHS),
        "databaseBackup": False,
        "isolatedTests": False,
    }
    (staging / "package.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return archive, metadata


def ssh_command(host: str, key: str, *command: str) -> list[str]:
    return [
        "ssh",
        "-i",
        key,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=15",
        host,
        *command,
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="快速发布整合版服务端，不备份数据库")
    parser.add_argument("--host", default=DEFAULT_HOST, help="SSH 目标，默认首尔服务器")
    parser.add_argument("--ssh-key", default=DEFAULT_SSH_KEY)
    parser.add_argument("--remote-root", default=DEFAULT_REMOTE_ROOT)
    parser.add_argument("--dry-run", action="store_true", help="只生成归档和命令，不连接服务器")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[2]
    remote_script = Path(__file__).with_name("quick_deploy_remote.py")
    if not remote_script.is_file():
        raise SystemExit(f"缺少远端快速部署脚本：{remote_script}")

    with tempfile.TemporaryDirectory(prefix="trade-tools-quick-") as temp_dir:
        staging = Path(temp_dir)
        archive, metadata = archive_source(repo, staging)
        remote_incoming = f"{args.remote_root}/incoming/{metadata['release']}"
        print(json.dumps({"target": args.host, **metadata, "remoteIncoming": remote_incoming}, ensure_ascii=False))
        if args.dry_run:
            print("dry-run：未连接服务器，未执行部署")
            return 0

        run(ssh_command(args.host, args.ssh_key, "mkdir", "-p", "-m", "700", remote_incoming))
        destination = f"{args.host}:{remote_incoming}/"
        run([
            "scp",
            "-i",
            args.ssh_key,
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            str(archive),
            str(staging / "package.json"),
            str(remote_script),
            destination,
        ])
        run(ssh_command(
            args.host,
            args.ssh_key,
            "python3",
            f"{remote_incoming}/quick_deploy_remote.py",
            remote_incoming,
        ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
