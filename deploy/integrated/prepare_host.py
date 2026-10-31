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
              DB_PASSWORD=secrets.token_hex(32), INTEGRATED_BOOTSTRAP_EMAIL="admin@integrated.local",
              INTEGRATED_BOOTSTRAP_PASSWORD=secrets.token_urlsafe(24))
sql = f"""CREATE DATABASE IF NOT EXISTS tradetools_integrated CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'tt_integrated'@'%' IDENTIFIED BY '{values['DB_PASSWORD']}';
GRANT ALL PRIVILEGES ON tradetools_integrated.* TO 'tt_integrated'@'%';
"""
subprocess.run(["docker", "exec", "-i", "trade_mysql", "sh", "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'], input=sql, text=True, check=True,
               stdout=subprocess.DEVNULL)
fd = os.open(environment, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as target:
    target.write("\n".join(f"{key}={value}" for key, value in values.items()) + "\n")
print("Independent database and restricted configuration ready")
