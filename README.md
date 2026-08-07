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
wget https://raw.githubusercontent.com/kzzou/cliproxyapi-installer/main/install_cpa_domain.sh

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

## 注意事项

- 仅支持 **Debian/Ubuntu** 系统
- 需要 **root** 权限运行
- 80 和 443 端口不能被其他服务占用（如 3x-ui 面板）
- 重复运行会自动备份旧配置，并复用之前的密钥
- 如果域名 DNS 尚未生效，脚本会提示是否继续

## 相关项目

- [CLIProxyAPI](https://github.com/eceasy/cli-proxy-api) - 上游 API 代理服务
- [Caddy](https://caddyserver.com/) - 自动 HTTPS 反向代理
