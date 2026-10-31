# 生产 Nginx

首尔独立测试服务器使用 [seoul-ip.conf](seoul-ip.conf)，入口为
`https://47.80.22.243`，直接加载 Certbot 管理的 IP 证书。该环境的路径、
六小时续期检查和验收记录见 [首尔测试部署](../../docs/SEOUL_DEPLOYMENT.md)。
下文保留原域名环境的部署说明。

生产服务器由宿主机 Nginx 独占公网 `80/443`。已有前端容器保留为内部上游：

```text
ba.wow211.com -> 宿主机 Nginx -> https://127.0.0.1:8444 -> 原前端容器
binance.oovso.com -> 宿主机 Nginx -> http://127.0.0.1:8686 -> trade_app
```

原前端的镜像、环境变量、数据卷和站点配置不变，只把宿主机端口收敛到
`127.0.0.1:8080/8444`。`existing-sites-proxy.conf` 记录原域名在宿主机 Nginx
上的等价转发配置；日常 Trade Tool Jenkins 发布不会再修改或重启原前端。

## Trade Tool 文件

Jenkins 会准备：

```text
/opt/trade-tool/nginx/trade-tool.conf.example
/opt/trade-tool/nginx/sync-certificate.sh
/opt/trade-tool/nginx/ssl/fullchain.pem
/opt/trade-tool/nginx/ssl/privkey.pem
```

SSL 目录权限为 `700`，私钥权限必须为 `600`。证书和私钥不得进入 Git、Jenkins
工作区或构建产物。

## 首次签发与启用

必须先确认 `binance.oovso.com` 已解析到生产服务器。现有静态卷可以继续提供
HTTP-01 challenge，不需要停止 Nginx：

```bash
certbot certonly \
  --webroot \
  --webroot-path /var/lib/docker/volumes/tradetools_static_data/_data \
  --domain binance.oovso.com

/opt/trade-tool/nginx/sync-certificate.sh

install -m 640 \
  /opt/trade-tool/nginx/trade-tool.conf.example \
  /etc/nginx/sites-available/trade-tool
ln -s /etc/nginx/sites-available/trade-tool /etc/nginx/sites-enabled/trade-tool

nginx -t
systemctl reload nginx
```

只有以下检查全部满足后才能启用配置：

1. `binance.oovso.com` DNS 已生效。
2. `/opt/trade-tool/nginx/ssl` 中存在有效证书和私钥。
3. `curl http://127.0.0.1:8686/api/auth/me` 返回 `200` 或 `401`。
4. `nginx -t` 成功。

宿主机 Nginx 使用标准端口 `443`；当前路由器将公网 `8443` 映射到该端口，因此外部
调用地址为 `https://binance.oovso.com:8443`。`/ws/v1` 由 `/ws/` location 完成协议升级。

## 自动续期

Certbot timer 已启用。安装项目的 deploy hook，使续期后自动复制证书并安全重载
宿主机 Nginx：

```bash
ln -s \
  /opt/trade-tool/nginx/sync-certificate.sh \
  /etc/letsencrypt/renewal-hooks/deploy/trade-tool-certificate

certbot renew --dry-run
```

脚本只处理 `binance.oovso.com`，不会覆盖已有 `ba.wow211.com` 证书。
