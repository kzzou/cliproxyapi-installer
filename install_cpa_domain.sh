#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/cliproxyapi"
STACK_NAME="cpa"
RESULT_FILE="${INSTALL_DIR}/install-result.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

on_error() {
  local line="$1"
  echo -e "${RED}[ERROR]${NC} 安装在第 ${line} 行失败。" >&2
  if [[ -d "$INSTALL_DIR" ]] && command -v docker >/dev/null 2>&1; then
    echo "最近日志：" >&2
    (cd "$INSTALL_DIR" && docker compose logs --tail=80 2>/dev/null) || true
  fi
}
trap 'on_error "$LINENO"' ERR

[[ $EUID -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
[[ -r /etc/os-release ]] || die "无法识别操作系统。"
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
  die "此脚本仅支持 Debian/Ubuntu 系。当前系统：${PRETTY_NAME:-unknown}"
fi

mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

# 复用上次安装生成的参数，避免重新运行脚本后 API Key 改变。
DOMAIN="${DOMAIN:-}"
PROXY_HOST="${PROXY_HOST:-}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
API_KEY="${API_KEY:-}"
MGMT_KEY="${MGMT_KEY:-}"
BASIC_USER="${BASIC_USER:-cpaadmin}"
BASIC_PASS="${BASIC_PASS:-}"

if [[ -f "${INSTALL_DIR}/credentials.env" ]]; then
  # shellcheck disable=SC1091
  source "${INSTALL_DIR}/credentials.env"
  info "检测到已有安装参数，将默认复用原来的密钥。"
fi

read_with_default() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  local input=""
  if [[ -n "$current" ]]; then
    read -r -p "${prompt} [${current}]: " input
    printf -v "$var_name" '%s' "${input:-$current}"
  else
    read -r -p "${prompt}: " input
    [[ -n "$input" ]] || die "${prompt}不能为空。"
    printf -v "$var_name" '%s' "$input"
  fi
}

read_secret_with_default() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  local input=""
  if [[ -n "$current" ]]; then
    read -r -s -p "${prompt} [直接回车保留原值]: " input
    echo
    printf -v "$var_name" '%s' "${input:-$current}"
  else
    read -r -s -p "${prompt}: " input
    echo
    [[ -n "$input" ]] || die "${prompt}不能为空。"
    printf -v "$var_name" '%s' "$input"
  fi
}

echo
info "请输入域名和购买的 SOCKS5 家宽代理信息。"
read_with_default DOMAIN "CPA 域名，例如 api.example.com"
read_with_default PROXY_HOST "SOCKS5 代理地址/IP"
read_with_default PROXY_PORT "SOCKS5 代理端口"
read_with_default PROXY_USER "SOCKS5 用户名"
read_secret_with_default PROXY_PASS "SOCKS5 密码"

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN%.}"

[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]] \
  || die "域名格式不正确：$DOMAIN"
[[ "$PROXY_HOST" != *"://"* && "$PROXY_HOST" != *"/"* && "$PROXY_HOST" != *" "* ]] \
  || die "代理地址只填写 IP 或主机名，不要包含协议、端口或路径。"
[[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "代理端口必须是数字。"
(( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "代理端口范围必须是 1~65535。"

info "安装基础工具……"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates openssl python3 iproute2

if ! command -v docker >/dev/null 2>&1; then
  info "安装 Docker……"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "Docker Compose 插件不可用。"

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

ENC_USER="$(urlencode "$PROXY_USER")"
ENC_PASS="$(urlencode "$PROXY_PASS")"
PROXY_URL="socks5://${ENC_USER}:${ENC_PASS}@${PROXY_HOST}:${PROXY_PORT}"

info "测试家宽 SOCKS5 代理……"
VPS_IP="$(curl -4fsS --connect-timeout 8 --max-time 15 https://api.ipify.org || true)"
PROXY_IP="$(curl -4fsS --connect-timeout 10 --max-time 30 \
  --proxy "socks5h://${PROXY_HOST}:${PROXY_PORT}" \
  --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
  https://api.ipify.org || true)"
[[ -n "$PROXY_IP" ]] || die "SOCKS5 代理连接失败。请检查地址、端口、账号密码，以及代理商是否要求添加 VPS IP 白名单。"
success "代理可用，检测到出口 IP：${PROXY_IP}"
if [[ -n "$VPS_IP" && "$VPS_IP" == "$PROXY_IP" ]]; then
  warn "代理出口 IP 与 VPS IP 相同，请确认供应商线路是否正确。"
fi

DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -n1 || true)"
if [[ -z "$DNS_IP" ]]; then
  warn "域名 $DOMAIN 暂时没有解析出 IPv4 地址。"
  read -r -p "仍然继续部署吗？证书将在 DNS 生效后自动申请。[y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "请先添加 A 记录：$DOMAIN -> ${VPS_IP:-VPS公网IP}"
elif [[ -n "$VPS_IP" && "$DNS_IP" != "$VPS_IP" ]]; then
  warn "域名当前解析为 $DNS_IP，但 VPS 公网 IP 是 $VPS_IP。"
  warn "使用 Cloudflare 时，请先设为“仅 DNS/灰云”。"
  read -r -p "仍然继续部署吗？[y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "请先修正 DNS A 记录。"
else
  success "域名已解析到当前 VPS：${DNS_IP}"
fi

# 停止旧的同名部署，再检查 80/443，便于安全重复运行。
if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
  BACKUP_DIR="${INSTALL_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  cp -a "${INSTALL_DIR}/config.yaml" "${INSTALL_DIR}/Caddyfile" \
        "${INSTALL_DIR}/docker-compose.yml" "${INSTALL_DIR}/credentials.env" \
        "$BACKUP_DIR" 2>/dev/null || true
  (cd "$INSTALL_DIR" && docker compose -p "$STACK_NAME" down) || true
  info "旧配置已备份到：$BACKUP_DIR"
fi

PORT_CONFLICT="$(ss -lntp 2>/dev/null | awk 'NR>1 && ($4 ~ /:80$/ || $4 ~ /:443$/) {print}' || true)"
if [[ -n "$PORT_CONFLICT" ]]; then
  echo "$PORT_CONFLICT"
  die "80 或 443 端口已被占用。若已安装 3x-ui，请把其入站改为 8443，并确保面板不使用 80/443。"
fi

API_KEY="${API_KEY:-sk-$(openssl rand -hex 24)}"
MGMT_KEY="${MGMT_KEY:-$(openssl rand -hex 32)}"
BASIC_USER="${BASIC_USER:-cpaadmin}"
BASIC_PASS="${BASIC_PASS:-$(openssl rand -hex 16)}"

mkdir -p "${INSTALL_DIR}/auths" "${INSTALL_DIR}/logs"
chmod 700 "${INSTALL_DIR}/auths" "${INSTALL_DIR}/logs"

info "准备 Caddy 管理页外层密码……"
docker pull caddy:2-alpine >/dev/null
BASIC_HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$BASIC_PASS")"

cat > "${INSTALL_DIR}/config.yaml" <<EOF
host: ""
port: 8317

tls:
  enable: false
  cert: ""
  key: ""

remote-management:
  allow-remote: true
  secret-key: "${MGMT_KEY}"
  disable-control-panel: false

api-keys:
  - "${API_KEY}"

auth-dir: "/root/.cli-proxy-api"

# 所有 CPA 上游请求统一通过购买的家宽 SOCKS5 代理。
proxy-url: "${PROXY_URL}"

debug: false
logging-to-file: true
logs-max-total-size-mb: 512
usage-statistics-enabled: false
request-retry: 3
max-retry-credentials: 2
EOF
chmod 600 "${INSTALL_DIR}/config.yaml"

cat > "${INSTALL_DIR}/Caddyfile" <<EOF
${DOMAIN} {
    encode zstd gzip

    # 管理页面使用额外的 HTTP Basic Auth；进入页面后仍需 CPA 管理密钥。
    @management {
        path /management.html /v0/management /v0/management/*
    }
    basic_auth @management {
        ${BASIC_USER} ${BASIC_HASH}
    }

    reverse_proxy cli-proxy-api:8317
}
EOF
chmod 600 "${INSTALL_DIR}/Caddyfile"

cat > "${INSTALL_DIR}/docker-compose.yml" <<'YAML'
services:
  cli-proxy-api:
    image: eceasy/cli-proxy-api:latest
    pull_policy: always
    container_name: cli-proxy-api
    restart: unless-stopped
    expose:
      - "8317"
    ports:
      - "127.0.0.1:8317:8317"
      - "127.0.0.1:8085:8085"
      - "127.0.0.1:1455:1455"
      - "127.0.0.1:54545:54545"
      - "127.0.0.1:51121:51121"
      - "127.0.0.1:11451:11451"
    volumes:
      - ./config.yaml:/CLIProxyAPI/config.yaml
      - ./auths:/root/.cli-proxy-api
      - ./logs:/CLIProxyAPI/logs
    networks:
      - cpa-net

  caddy:
    image: caddy:2-alpine
    container_name: cpa-caddy
    restart: unless-stopped
    depends_on:
      - cli-proxy-api
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - cpa-net

networks:
  cpa-net:
    name: cpa-net

volumes:
  caddy-data:
  caddy-config:
YAML

# 使用 shell 可安全再次 source 的格式保存安装参数。
# 注意：使用 %s 而非 %q，避免 bash 版本差异导致转义不一致。
{
  printf 'DOMAIN=%s\n' "$DOMAIN"
  printf 'PROXY_HOST=%s\n' "$PROXY_HOST"
  printf 'PROXY_PORT=%s\n' "$PROXY_PORT"
  printf 'PROXY_USER=%s\n' "$PROXY_USER"
  printf 'PROXY_PASS=%s\n' "$PROXY_PASS"
  printf 'API_KEY=%s\n' "$API_KEY"
  printf 'MGMT_KEY=%s\n' "$MGMT_KEY"
  printf 'BASIC_USER=%s\n' "$BASIC_USER"
  printf 'BASIC_PASS=%s\n' "$BASIC_PASS"
} > "${INSTALL_DIR}/credentials.env"
chmod 600 "${INSTALL_DIR}/credentials.env"

info "校验配置……"
cd "$INSTALL_DIR"
docker compose -p "$STACK_NAME" config >/dev/null
docker run --rm \
  -v "${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  info "已在现有 UFW 中放行 80/TCP、443/TCP、443/UDP。"
fi

info "拉取并启动 CPA 与 Caddy……"
docker compose -p "$STACK_NAME" pull
docker compose -p "$STACK_NAME" up -d --remove-orphans

cat > /usr/local/bin/cpa-update <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${INSTALL_DIR}"
docker compose -p "${STACK_NAME}" pull
docker compose -p "${STACK_NAME}" up -d --remove-orphans
docker image prune -f
EOF
chmod 755 /usr/local/bin/cpa-update

info "等待 HTTPS 证书签发……"
HTTPS_OK=0
for _ in $(seq 1 40); do
  HTTP_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 12 \
    -u "${BASIC_USER}:${BASIC_PASS}" \
    "https://${DOMAIN}/management.html" 2>/dev/null || true)"
  if [[ "$HTTP_CODE" == "200" ]]; then
    HTTPS_OK=1
    break
  fi
  sleep 3
done

cat > "$RESULT_FILE" <<EOF
CPA 安装结果
============

API Base URL: https://${DOMAIN}/v1
API Key: ${API_KEY}

管理页面: https://${DOMAIN}/management.html
管理页外层用户名: ${BASIC_USER}
管理页外层密码: ${BASIC_PASS}
CPA 管理密钥: ${MGMT_KEY}

家宽代理出口 IP: ${PROXY_IP}
VPS 直连 IP: ${VPS_IP:-unknown}

安装目录: ${INSTALL_DIR}
查看状态: cd ${INSTALL_DIR} && docker compose -p ${STACK_NAME} ps
查看日志: cd ${INSTALL_DIR} && docker compose -p ${STACK_NAME} logs -f
更新服务: cpa-update
停止服务: cd ${INSTALL_DIR} && docker compose -p ${STACK_NAME} down
启动服务: cd ${INSTALL_DIR} && docker compose -p ${STACK_NAME} up -d
EOF
chmod 600 "$RESULT_FILE"

echo
if [[ "$HTTPS_OK" -eq 1 ]]; then
  success "CPA、域名和 HTTPS 已部署完成。"
else
  warn "CPA 已启动，但 HTTPS 暂未验证成功。通常是 DNS 尚未生效、云防火墙未开放 80/443，或端口被上游安全组拦截。"
  echo "查看 Caddy 日志：cd ${INSTALL_DIR} && docker compose -p ${STACK_NAME} logs --tail=100 caddy"
fi

echo
cat "$RESULT_FILE"
echo
warn "请妥善保存以上密钥；完整结果已保存到 $RESULT_FILE（权限 600）。"
warn "VPS 厂商安全组必须开放 TCP 80、TCP 443；HTTP/3 可选开放 UDP 443。"
warn "以后安装 3x-ui 时，请将 VPN 入站设为 8443 或其他端口，不要占用 80/443。"
