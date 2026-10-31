"""Run on the authorized integration host; credentials remain in a mode-600 file."""
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path("/opt/trade-tools-integrated")
ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
environment = ROOT / "server.env"
if environment.exists():
    raise SystemExit("Existing configuration preserved; use release.sh to update")
values = {}
template = Path(__file__).with_name("server.env.example")
for line in template.read_text().splitlines():
    if line and not line.startswith("#"):
        key, value = line.split("=", 1)
        values[key] = value
values.update(SECRET_KEY=secrets.token_urlsafe(48), AES_SECRET_KEY=secrets.token_urlsafe(48),
              DB_PASSWORD=secrets.token_hex(32), MYSQL_ROOT_PASSWORD=secrets.token_hex(32),
              INTEGRATED_BOOTSTRAP_EMAIL="admin@integrated.local",
              INTEGRATED_BOOTSTRAP_PASSWORD=secrets.token_urlsafe(24))
fd = os.open(environment, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as target:
    target.write("\n".join(f"{key}={value}" for key, value in values.items()) + "\n")
release = Path(__file__).resolve().parents[2]
link = release / "server.env"
if link != environment:
    if link.exists() or link.is_symlink():
        raise SystemExit("Release server.env already exists; configuration preserved")
    link.symlink_to(environment)
subprocess.run(["docker", "compose", "--project-name", "tradetools-integrated",
                "--env-file", str(environment), "-f", str(release / "compose.integrated.yaml"),
                "--profile", "pro", "up", "-d", "--wait", "mysql"], check=True)
print("Independent MySQL and restricted configuration ready; run release.sh next")
