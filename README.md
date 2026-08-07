# CLIProxyAPI 一键安装脚本

在 Debian/Ubuntu VPS 上自动部署 [CLIProxyAPI](https://github.com/eceasy/cli-proxy-api)（CPA），集成 Caddy 自动 HTTPS 和 SOCKS5 家宽代理。

## 功能

- 自动安装 Docker 和 Docker Compose
- 部署 CLIProxyAPI + Caddy（自动 Let's Encrypt 证书）
- 配置 SOCKS5 家宽代理作为上游出口
- HTTP Basic Auth 保护管理页面
- 支持重复运行（自动备份旧配置、复用密钥）
- 创建 `cpa-update` 快捷更新命令

## 使用方法

### 1. 准备工作

- 一台 **Debian/Ubuntu** VPS（root 权限）
- 一个已解析到 VPS IP 的**域名**（使用 Cloudflare 时请开启"仅 DNS/灰云"）
- 一个 **SOCKS5 家宽代理**（IP、端口、用户名、密码）
- VPS 安全组/防火墙开放 **TCP 80** 和 **TCP 443**（HTTP/3 可选开放 UDP 443）

### 2. 下载并运行

```bash
# 下载脚本
wget https://raw.githubusercontent.com/kzzou/cliproxyapi-installer/master/install_cpa_domain.sh

# 赋予执行权限
chmod +x install_cpa_domain.sh

# 以 root 运行
sudo bash install_cpa_domain.sh
```

### 3. 按提示输入

脚本会交互式询问：
- **域名**（如 `api.example.com`）
- **SOCKS5 代理地址/IP**
- **SOCKS5 代理端口**
- **SOCKS5 用户名**
- **SOCKS5 密码**

### 4. 完成

安装成功后，脚本会输出：

| 项目 | 说明 |
|------|------|
| API Base URL | `https://你的域名/v1` |
| API Key | 自动生成的 API 密钥 |
| 管理页面 | `https://你的域名/management.html` |
| 管理页用户名 | 默认 `cpaadmin` |
| 管理页密码 | 自动生成 |

所有密钥保存在 `/opt/cliproxyapi/install-result.txt`（权限 600）。

## 常用命令

```bash
# 查看服务状态
cd /opt/cliproxyapi && docker compose -p cpa ps

# 查看日志
cd /opt/cliproxyapi && docker compose -p cpa logs -f

# 更新到最新版本
cpa-update

# 停止服务
cd /opt/cliproxyapi && docker compose -p cpa down

# 启动服务
cd /opt/cliproxyapi && docker compose -p cpa up -d
```

## 目录结构

```
/opt/cliproxyapi/
├── config.yaml          # CPA 配置文件
├── Caddyfile            # Caddy 反向代理配置
├── docker-compose.yml   # Docker Compose 编排
├── credentials.env      # 安装参数（可 source 复用）
├── auths/               # CPA 认证数据
├── logs/                # CPA 日志
└── install-result.txt   # 安装结果（密钥信息）
```

## 安全说明

### 两层认证

| 路径 | 认证方式 |
|------|----------|
| `/management.html` | Caddy HTTP Basic Auth（用户名 + 密码） |
| `/v0/management/*` | CPA 自身的 Bearer token（管理密钥） |
| `/v1/*` | API Key |

管理 API **不能**加 Basic Auth——管理页面的 JS 会发送 `Authorization: Bearer <管理密钥>`，
而一个请求只能带一个 `Authorization` 头，Basic 会被 Bearer 覆盖，导致 Caddy 反复弹出登录框且永远无法通过。

### 需要注意的暴露面

因为上述限制，`/v0/management/*` 直接暴露在公网，只靠 CPA 的 Bearer token 防护，且**没有速率限制**。
如果你的管理来源 IP 固定，建议在 `/opt/cliproxyapi/Caddyfile` 中取消 `@mgmt_api_denied` 那段注释并填入自己的 IP，
然后执行 `cd /opt/cliproxyapi && docker compose -p cpa restart caddy`。

### OAuth 回调端口

CPA 用于登录上游账号的回调端口（8085/1455/54545/51121/11451）只绑定在 `127.0.0.1`，不对公网开放。
如果需要在面板里登录上游账号，请先建立 SSH 隧道，例如：

```bash
ssh -L 8085:127.0.0.1:8085 root@你的VPS
```

## 注意事项

- 仅支持 **Debian/Ubuntu** 系统
- 需要 **root** 权限运行
- 80 和 443 端口不能被其他服务占用（如 3x-ui 面板）
- 重复运行会自动备份旧配置，并复用之前的密钥
- **重复运行会覆盖 `config.yaml`**：如果你在管理面板里手工添加过账号或模型配置，
  重跑前请先备份（脚本会自动备份到 `backup-*/`，但不会自动恢复）
- 如果域名 DNS 尚未生效，脚本会提示是否继续

## 相关项目

- [CLIProxyAPI](https://github.com/eceasy/cli-proxy-api) - 上游 API 代理服务
- [Caddy](https://caddyserver.com/) - 自动 HTTPS 反向代理
