#!/usr/bin/env bash
#
# one-step-wg: WireGuard 一键部署脚本
# WireGuard (linuxserver) + wg-api + wg-gen-web
#

set -euo pipefail

# ========================= 默认值 =========================
DEFAULT_WG_SUBNET="10.8.0.0/24"
DEFAULT_WG_PORT="65001"
DEFAULT_WG_DNS="8.8.8.8"
DEFAULT_WG_MTU="1280"
DEFAULT_TABLE_NAME="wireguard"
DEFAULT_TABLE_ID="9999"
DEFAULT_API_PORT="65002"
DEFAULT_WEB_PORT="65003"
DEFAULT_OAUTH="file"
DEFAULT_PEER_COUNT="1"
DEFAULT_PEER_KEEPALIVE=""
DEFAULT_DEPLOY_DIR="/opt/one-step-wg"
DEFAULT_IMAGE_DIR="$(pwd)"
DEFAULT_ADMIN_USER="admin"
DEFAULT_ADMIN_PASS="admin"

# Phantun UDP-to-TCP obfuscation（默认关闭）
DEFAULT_PHANTUN_ENABLE="false"
DEFAULT_PHANTUN_PORT="65000"

# 客户端默认 AllowedIPs
DEFAULT_PEER_ALLOWED_IPS="0.0.0.0/0"

# DNSCrypt（默认关闭）
DEFAULT_DNSCRYPT_ENABLE="false"
DEFAULT_DNSCRYPT_NAME="dns.local"
DEFAULT_DNSCRYPT_PORT="5443"

# ========================= 颜色输出 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# ========================= 交互输入 =========================
read_input() {
    local prompt="$1" default="$2"
    local input
    if [ -n "$default" ]; then
        read -rp "${prompt} [${default}]: " input
    else
        read -rp "${prompt}: " input
    fi
    echo "${input:-$default}"
}

interactive_setup() {
    echo "============================================="
    echo "  one-step-wg: WireGuard 一键部署"
    echo "============================================="
    echo ""

    WG_SUBNET=$(read_input "WireGuard 内网段" "$DEFAULT_WG_SUBNET")
    WG_SERVER_IP=$(read_input "WireGuard 服务器 IP" "${WG_SUBNET%.*}.1")
    WG_SERVER_CIDR="${WG_SERVER_IP}/24"
    WG_PORT=$(read_input "WireGuard 监听端口 (UDP)" "$DEFAULT_WG_PORT")
    WG_DNS=$(read_input "客户端 DNS" "$DEFAULT_WG_DNS")
    WG_MTU="1280"

    TABLE_NAME="$DEFAULT_TABLE_NAME"
    TABLE_ID="$DEFAULT_TABLE_ID"

    API_PORT=$(read_input "wg-api 端口" "$DEFAULT_API_PORT")
    WEB_PORT=$(read_input "wg-gen-web 端口" "$DEFAULT_WEB_PORT")
    OAUTH=$(read_input "认证方式 (file/fake/github/oauth2oidc)" "$DEFAULT_OAUTH")

    PEER_COUNT="$DEFAULT_PEER_COUNT"
    PEER_KEEPALIVE="25"
    PEER_ALLOWED_IPS="$DEFAULT_PEER_ALLOWED_IPS"
    # 追加服务器 wg0 IP
    PEER_ALLOWED_IPS="${PEER_ALLOWED_IPS}, ${WG_SERVER_IP}/32"

    ADMIN_USER=$(read_input "Web UI 用户名" "$DEFAULT_ADMIN_USER")
    ADMIN_PASS=$(read_input "Web UI 密码" "$DEFAULT_ADMIN_PASS")

    PHANTUN_ENABLE=$(read_input "启用 Phantun UDP-to-TCP (true/false)" "$DEFAULT_PHANTUN_ENABLE")
    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        PHANTUN_PORT=$(read_input "Phantun TCP 监听端口" "$DEFAULT_PHANTUN_PORT")
    else
        PHANTUN_PORT=""
    fi

    DNSCRYPT_ENABLE=$(read_input "启用 DNSCrypt (true/false)" "$DEFAULT_DNSCRYPT_ENABLE")
    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        DNSCRYPT_NAME=$(read_input "DNSCrypt Provider Name" "$DEFAULT_DNSCRYPT_NAME")
        DNSCRYPT_PORT=$(read_input "DNSCrypt 监听端口" "$DEFAULT_DNSCRYPT_PORT")
    else
        DNSCRYPT_NAME=""
        DNSCRYPT_PORT=""
    fi

    DEPLOY_DIR=$(read_input "部署目录" "$DEFAULT_DEPLOY_DIR")
    IMAGE_DIR=$(read_input "镜像 tar 文件目录" "$DEFAULT_IMAGE_DIR")
    # 展开 ~ 为实际路径
    IMAGE_DIR="${IMAGE_DIR/#\~/$HOME}"

    echo ""
    echo "============================================="
    echo "  配置汇总"
    echo "============================================="
    echo "  内网段:           ${WG_SUBNET}"
    echo "  服务器 IP:        ${WG_SERVER_CIDR}"
    echo "  监听端口:         ${WG_PORT}/udp"
    echo "  客户端 DNS:       ${WG_DNS}"
    echo "  MTU:              ${WG_MTU}"
    echo "  路由表:           ${TABLE_ID} ${TABLE_NAME}"
    echo "  wg-api 端口:      ${API_PORT}"
    echo "  Web UI 端口:      ${WEB_PORT}"
    echo "  认证:             ${OAUTH}"
    if [ "${OAUTH}" = "file" ]; then
        echo "  Web UI 用户名:    ${ADMIN_USER}"
        echo "  Web UI 密码:      ${ADMIN_PASS}"
    fi
    echo "  初始客户端数:     ${PEER_COUNT}"
    echo "  客户端 AllowedIPs: (共 $(echo "$PEER_ALLOWED_IPS" | tr ',' '\n' | wc -l) 条路由)"
    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        echo "  Phantun:          启用 (TCP ${PHANTUN_PORT})"
    else
        echo "  Phantun:          未启用"
    fi
    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        echo "  DNSCrypt:         启用 (${DNSCRYPT_NAME} @ ${WG_SERVER_IP}:${DNSCRYPT_PORT})"
    else
        echo "  DNSCrypt:         未启用"
    fi
    echo "  部署目录:         ${DEPLOY_DIR}"
    echo "  镜像目录:         ${IMAGE_DIR}"
    echo "============================================="
    echo ""
    read -rp "确认部署? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        exit 0
    fi
}

# ========================= 环境检查 =========================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 用户或 sudo 运行此脚本"
        exit 1
    fi
}

# ========================= 系统检查 =========================
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        log_error "无法识别操作系统"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu)
            log_info "操作系统: Ubuntu $OS_VERSION"
            OS_CODENAME="$VERSION_CODENAME"
            if [ -z "$OS_CODENAME" ]; then
                case "$OS_VERSION" in
                    24.04) OS_CODENAME="noble" ;;
                    22.04) OS_CODENAME="jammy" ;;
                    20.04) OS_CODENAME="focal" ;;
                    *) log_error "不支持的 Ubuntu 版本: $OS_VERSION" ; exit 1 ;;
                esac
            fi
            ;;
        debian)
            log_info "操作系统: Debian $OS_VERSION"
            # 尝试从 VERSION_CODENAME 获取，否则查 Debian 版本映射
            OS_CODENAME="$VERSION_CODENAME"
            if [ -z "$OS_CODENAME" ]; then
                case "$OS_VERSION" in
                    12*) OS_CODENAME="bookworm" ;;
                    11*) OS_CODENAME="bullseye" ;;
                    10*) OS_CODENAME="buster" ;;
                    *) log_error "不支持的 Debian 版本: $OS_VERSION" ; exit 1 ;;
                esac
            fi
            ;;
        *)
            log_error "不支持的操作系统: $OS_ID (仅支持 Ubuntu / Debian)"
            exit 1
            ;;
    esac
}

# ========================= Docker 安装 =========================
install_docker() {
    log_step "安装 Docker Engine (官方源)..."

    # 1. 卸载旧版本
    log_info "清理旧版本 Docker..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # 2. 安装依赖
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # 3. 添加 Docker GPG 密钥
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | \
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    log_info "Docker GPG 密钥已添加"

    # 4. 添加 Docker 源（DEB822 格式）
    local sources_file="/etc/apt/sources.list.d/docker.sources"
    rm -f "$sources_file" 2>/dev/null || true
    cat > "$sources_file" << EOF
Types: deb
URIs: https://download.docker.com/linux/${OS_ID}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
EOF
    log_info "Docker 源已添加: ${sources_file}"

    # 5. 安装 Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    # 6. 启用并启动服务
    systemctl enable --now docker

    log_info "Docker 安装完成: $(docker --version)"
}

# ========================= Docker 源检查 =========================
setup_docker_repo() {
    # 检查 apt 是否能找到 docker-compose-plugin（需要官方源）
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
        log_info "Docker 官方源可用"
        return 0
    fi

    log_step "添加 Docker 官方 apt 源..."

    # 安装依赖
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # 添加 GPG 密钥
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | \
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg

    # 添加源（DEB822 格式）
    cat > /etc/apt/sources.list.d/docker.sources << EOF
Types: deb
URIs: https://download.docker.com/linux/${OS_ID}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
EOF

    apt-get update
    log_info "Docker 官方源已添加"
}

check_docker() {
    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
    else
        install_docker
    fi

    # 确保官方源存在（否则 docker-compose-plugin 等包找不到）
    setup_docker_repo

    # 检测 compose
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        log_info "Compose: $($COMPOSE_CMD version 2>&1)"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        log_warn "使用 docker-compose v1: $($COMPOSE_CMD version 2>&1)"
    else
        # 没有 compose，从 Docker 官方源安装
        log_warn "docker compose 未安装，正在安装..."
        apt-get update
        apt-get install -y docker-compose-plugin
        if ! docker compose version >/dev/null 2>&1; then
            log_error "docker compose 安装失败，请手动执行: apt install docker-compose-plugin"
            exit 1
        fi
        COMPOSE_CMD="docker compose"
        log_info "Compose: $($COMPOSE_CMD version 2>&1)"
    fi
}

# ========================= 宿主机初始化 =========================
setup_rt_tables() {
    local rt_dir="/etc/iproute2/rt_tables.d"
    local rt_file="${rt_dir}/wg.conf"

    mkdir -p "$rt_dir"
    if [ -f "$rt_file" ] && grep -q "${TABLE_ID} ${TABLE_NAME}" "$rt_file" 2>/dev/null; then
        log_info "路由表已存在: ${TABLE_ID} ${TABLE_NAME}"
    else
        echo "${TABLE_ID} ${TABLE_NAME}" > "$rt_file"
        log_info "写入路由表: ${rt_file} -> ${TABLE_ID} ${TABLE_NAME}"
    fi
}

setup_host_sysctl() {
    # host 网络模式下，必须在宿主机设置 sysctl
    if sysctl -w net.ipv4.conf.all.src_valid_mark=1 2>/dev/null; then
        log_info "已设置 net.ipv4.conf.all.src_valid_mark=1"
    fi

    # 持久化
    local conf="/etc/sysctl.d/99-wireguard.conf"
    if ! grep -q "net.ipv4.conf.all.src_valid_mark" "$conf" 2>/dev/null; then
        echo "net.ipv4.conf.all.src_valid_mark=1" >> "$conf"
        log_info "已持久化 sysctl 到 $conf"
    fi

    # 开启 IP 转发
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-wireguard.conf
        log_info "已开启 IP 转发"
    fi
}

# ========================= 生成文件 =========================

# 辅助函数：逗号分隔的 IP 列表转 JSON 数组
ips_to_json_array() {
    local ips="$1"
    local result="["
    local first=true
    IFS=',' read -ra ADDR <<< "$ips"
    for ip in "${ADDR[@]}"; do
        ip=$(echo "$ip" | sed 's/^ *//;s/ *$//')
        if [ -n "$ip" ]; then
            if [ "$first" = true ]; then
                first=false
            else
                result="${result}, "
            fi
            result="${result}\"$ip\""
        fi
    done
    result="${result}]"
    echo "$result"
}

generate_wg_configs() {
    local config_dir="${DEPLOY_DIR}/wireguard/config"
    mkdir -p "$config_dir"

    # 生成服务器密钥对
    local server_privkey server_pubkey
    server_privkey=$(wg genkey)
    server_pubkey=$(echo "$server_privkey" | wg pubkey)

    # 生成初始客户端密钥对
    local client_privkey client_pubkey client_psk client_ip
    client_privkey=$(wg genkey)
    client_pubkey=$(echo "$client_privkey" | wg pubkey)
    client_psk=$(wg genpsk)
    client_ip="${WG_SUBNET%.*}.2"

    # 保存密钥信息
    cat > "${DEPLOY_DIR}/keys.txt" << EOF
# WireGuard 密钥对
# 服务器公钥: ${server_pubkey}
# 服务器私钥: ${server_privkey}
# 客户端 1 公钥: ${client_pubkey}
# 客户端 1 私钥: ${client_privkey}
# 客户端 1 PSK: ${client_psk}
EOF

    local server_external_ip
    server_external_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 1. 生成 server.json（wg-gen-web 的配置源）
    local server_allowed_ips_json
    server_allowed_ips_json=$(ips_to_json_array "$PEER_ALLOWED_IPS")
    cat > "${config_dir}/server.json" << EOF
{
  "address": ["${WG_SERVER_CIDR}"],
  "listenPort": ${WG_PORT},
  "mtu": ${WG_MTU},
  "privateKey": "${server_privkey}",
  "publicKey": "${server_pubkey}",
  "endpoint": "${server_external_ip}:${WG_PORT}",
  "persistentKeepalive": ${PEER_KEEPALIVE},
  "dns": ["${WG_DNS}"],
  "allowedips": ${server_allowed_ips_json},
  "preUp": "",
  "postUp": "/etc/wireguard/up.d/0000wg0",
  "preDown": "/etc/wireguard/pre-down.d/0000wg0",
  "postDown": "",
  "updatedBy": "one-step-wg",
  "created": "${now}",
  "updated": "${now}"
}
EOF
    log_info "生成 server.json"
    log_info "服务器公钥: ${server_pubkey}"

    # 2. 生成客户端 JSON（wg-gen-web 要求文件名必须是 UUID）
    local client_uuid
    if command -v uuidgen &>/dev/null; then
        client_uuid=$(uuidgen)
    else
        # fallback: 从 /proc 读取随机 UUID
        client_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-4$(openssl rand -hex 3)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
    fi
    local allowed_ips_json
    allowed_ips_json=$(ips_to_json_array "$PEER_ALLOWED_IPS")
    # wg-gen-web 的 ReadClients 通过 uuid.FromString(f.Name()) 匹配文件名，
    # 文件名必须就是 UUID 本身，不能有任何后缀（如 .json）
    cat > "${config_dir}/${client_uuid}" << EOF
{
  "id": "${client_uuid}",
  "name": "peer1",
  "email": "",
  "enable": true,
  "ignorePersistentKeepalive": false,
  "presharedKey": "${client_psk}",
  "allowedIPs": ${allowed_ips_json},
  "address": ["${client_ip}/32"],
  "tags": [],
  "privateKey": "${client_privkey}",
  "publicKey": "${client_pubkey}",
  "createdBy": "one-step-wg",
  "updatedBy": "one-step-wg",
  "created": "${now}",
  "updated": "${now}"
}
EOF
    log_info "生成客户端配置: ${client_uuid}"

    # 3. 生成初始 wg0.conf（供 wireguard 容器首次启动使用）
    cat > "${config_dir}/wg0.conf" << EOF
[Interface]
Address = ${WG_SERVER_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = ${server_privkey}
MTU = ${WG_MTU}
Table = ${TABLE_NAME}
SaveConfig = true
PostUp = /etc/wireguard/up.d/0000wg0
PreDown = /etc/wireguard/pre-down.d/0000wg0

[Peer]
# Client: peer-1
PublicKey = ${client_pubkey}
PresharedKey = ${client_psk}
AllowedIPs = ${client_ip}/32
EOF
    chmod 600 "${config_dir}/wg0.conf"
    log_info "生成 wg0.conf"

    # 4. 生成 users.txt（文件认证模式使用）
    if [ "${OAUTH}" = "file" ]; then
        cat > "${config_dir}/users.txt" << EOF
# WireGuard Web UI 用户认证文件
# 格式: username:password
${ADMIN_USER}:${ADMIN_PASS}
EOF
        chmod 600 "${config_dir}/users.txt"
        log_info "生成 users.txt (用户: ${ADMIN_USER})"
    fi
}

generate_up_script() {
    local up_dir="${DEPLOY_DIR}/wireguard/config/up.d"
    mkdir -p "$up_dir"

    cat > "${up_dir}/0000wg0" << UPSCRIPT
#!/bin/bash
# WireGuard up 脚本 - 配置 NAT 和路由
WG_SUBNET="${WG_SUBNET}"
NAT_IFACE="\$(ip route show default | awk '/default/ {print \$5; exit}')"

echo "[wg-up] Configuring NAT and routing for \${WG_SUBNET} via \${NAT_IFACE}"

# iptables NAT 规则（幂等：先检查再添加）
iptables -t nat -C POSTROUTING -s \${WG_SUBNET} -o \${NAT_IFACE} -j MASQUERADE 2>/dev/null || \\
  iptables -t nat -A POSTROUTING -s \${WG_SUBNET} -o \${NAT_IFACE} -j MASQUERADE
iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -j ACCEPT
iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o wg0 -j ACCEPT

# TCP MSS clamping（防止隧道内 TCP 握手问题）
iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# ip route: 客户端 IP 段加入自定义路由表
ip route add \${WG_SUBNET} dev wg0 table ${TABLE_ID} 2>/dev/null || true

echo "[wg-up] Done"
UPSCRIPT

    # 添加 ip rule（确保流量能使用自定义路由表，幂等检查）
    echo "ip rule show | grep -q \"table ${TABLE_ID}\" || ip rule add from 0.0.0.0/0 table ${TABLE_ID}" >> "${up_dir}/0000wg0"

    chmod +x "${up_dir}/0000wg0"
    log_info "生成 up.d/0000wg0"
}

generate_down_script() {
    local down_dir="${DEPLOY_DIR}/wireguard/config/pre-down.d"
    mkdir -p "$down_dir"

    cat > "${down_dir}/0000wg0" << DOWNSCRIPT
#!/bin/bash
# WireGuard down 脚本 - 清理 NAT 和路由
WG_SUBNET="${WG_SUBNET}"
NAT_IFACE="\$(ip route show default | awk '/default/ {print \$5; exit}')"

echo "[wg-down] Cleaning up NAT and routing for \${WG_SUBNET}"

# 清理 iptables
iptables -t nat -D POSTROUTING -s \${WG_SUBNET} -o \${NAT_IFACE} -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null

# 清理 TCP MSS clamping
iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
ip6tables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

# 清理 ip route
ip route del \${WG_SUBNET} dev wg0 table ${TABLE_ID} 2>/dev/null

echo "[wg-down] Done"
DOWNSCRIPT

    echo "ip rule show | grep -q \"table ${TABLE_ID}\" && ip rule del from 0.0.0.0/0 table ${TABLE_ID}" >> "${down_dir}/0000wg0"

    chmod +x "${down_dir}/0000wg0"
    log_info "生成 pre-down.d/0000wg0"
}

generate_docker_compose() {
    local WG_API_IMAGE="james/wg-api:latest"
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')

    cat > "${DEPLOY_DIR}/docker-compose.yml" << EOF
services:
  wireguard:
    image: one-step-wg:0.0.3
    container_name: wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    network_mode: host
    volumes:
      - ./wireguard/config:/etc/wireguard
      - /etc/iproute2/rt_tables.d:/etc/iproute2/rt_tables.d:ro
    restart: unless-stopped

  wg-api:
    image: ${WG_API_IMAGE}
    container_name: wg-api
    cap_add:
      - NET_ADMIN
    network_mode: host
    command: wg-api --device wg0 --listen 0.0.0.0:${API_PORT}
    restart: unless-stopped

  wg-gen-web:
    image: wg-gen-web:0.0.2
    container_name: wg-gen-web
    environment:
      - WG_CONF_DIR=/config
      - WG_INTERFACE_NAME=wg0.conf
      - WG_STATS_API=http://${host_ip}:${API_PORT}
      - OAUTH2_PROVIDER_NAME=${OAUTH}
    ports:
      - "${WEB_PORT}:8080"
    volumes:
      - ./wireguard/config:/config
    restart: unless-stopped
    depends_on:
      - wireguard
EOF

    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        cat >> "${DEPLOY_DIR}/docker-compose.yml" << EOF

  phantun:
    image: zcb617/phantun:0.8.1
    container_name: phantun
    cap_add:
      - NET_ADMIN
    network_mode: host
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - USE_IPTABLES_NFT_BACKEND=0
      - RUST_LOG=INFO
    command: phantun-server --local ${PHANTUN_PORT} --remote 127.0.0.1:${WG_PORT} --ipv4-only
    restart: unless-stopped
    depends_on:
      - wireguard
EOF
    fi

    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        cat >> "${DEPLOY_DIR}/docker-compose.yml" << EOF

  dnscrypt:
    image: jedisct1/dnscrypt-server:latest
    container_name: dnscrypt
    network_mode: host
    volumes:
      - ./dnscrypt/keys:/opt/encrypted-dns/etc/keys
    restart: unless-stopped
    command: start
    depends_on:
      - wireguard
EOF
    fi

    log_info "生成 docker-compose.yml"
}

# ========================= 修正 wg0.conf =========================
patch_wg0_conf() {
    local conf_file="${DEPLOY_DIR}/wireguard/config/wg0.conf"
    if [ ! -f "$conf_file" ]; then
        return
    fi

    # 删除空的 PreUp / PostDown 行
    sed -i '/^PreUp = $/d' "$conf_file"
    sed -i '/^PostDown = $/d' "$conf_file"

    # 添加 Table（如缺失）
    if ! grep -q "^Table = " "$conf_file"; then
        sed -i '/^\[Interface\]$/a Table = '${TABLE_NAME} "$conf_file"
    fi

    # 添加 SaveConfig（如缺失）
    if ! grep -q "^SaveConfig = " "$conf_file"; then
        sed -i '/^\[Interface\]$/a SaveConfig = true' "$conf_file"
    fi

    log_info "已修正 wg0.conf"
}

# ========================= 启动 =========================
start_services() {
    cd "$DEPLOY_DIR"

    log_step "启动服务..."
    $COMPOSE_CMD up -d

    log_step "等待 WireGuard 容器就绪..."
    for i in $(seq 1 30); do
        if docker exec wireguard wg show wg0 2>/dev/null | head -1; then
            log_info "WireGuard 接口已就绪"
            break
        fi
        if [ "$i" -eq 30 ]; then
            log_warn "WireGuard 可能还在初始化，请查看日志"
        fi
        sleep 2
    done

    # 等待 wg-gen-web 就绪（它可能会基于 server.json 重写 wg0.conf）
    log_step "等待 wg-gen-web 就绪..."
    for i in $(seq 1 30); do
        if curl -sf -m 2 "http://127.0.0.1:${WEB_PORT}" >/dev/null 2>&1; then
            log_info "wg-gen-web 已就绪"
            break
        fi
        if [ "$i" -eq 30 ]; then
            log_warn "wg-gen-web 启动较慢，继续执行..."
        fi
        sleep 2
    done

    # 修正 wg-gen-web 生成的 wg0.conf（删除空行、补 Table/SaveConfig）
    patch_wg0_conf

    # 热重载 WireGuard（应用最新的 wg0.conf）
    log_step "热重载 WireGuard..."
    docker exec wireguard bash -c 'wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || echo "[reload] wg0 not running yet, will be applied on next restart"'
}

# ========================= 验证 =========================
verify_deployment() {
    echo ""
    echo "============================================="
    echo "  部署验证"
    echo "============================================="

    local ok=true

    # 检查容器
    echo -n "  容器状态: "
    if $COMPOSE_CMD ps 2>/dev/null | grep -qiE 'running|up'; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}异常${NC}"
        $COMPOSE_CMD ps
        ok=false
    fi

    # 检查 wg0 接口
    echo -n "  WireGuard 接口: "
    if docker exec wireguard wg show wg0 2>/dev/null | grep -q "interface"; then
        echo -e "${GREEN}wg0 可用${NC}"
    else
        echo -e "${RED}wg0 不可用${NC}"
        ok=false
    fi

    # 检查 wg0.conf 内容
    echo -n "  wg0.conf 关键行: "
    local conf_file="${DEPLOY_DIR}/wireguard/config/wg0.conf"
    if [ -f "$conf_file" ]; then
        local missing=""
        grep -q "^MTU = " "$conf_file" 2>/dev/null || missing="${missing} MTU"
        grep -q "^PostUp = " "$conf_file" 2>/dev/null || missing="${missing} PostUp"
        grep -q "^PreDown = " "$conf_file" 2>/dev/null || missing="${missing} PreDown"
        if [ -z "$missing" ]; then
            echo -e "${GREEN}完整${NC}"
        else
            echo -e "${YELLOW}缺少:${missing}${NC}"
        fi
    else
        echo -e "${YELLOW}wg0.conf 不存在${NC}"
    fi

    # 检查路由表（ip rule show 在有 rt_tables 映射时显示名称而非数字ID）
    echo -n "  路由表 ${TABLE_ID}: "
    if ip rule show | grep -qE "${TABLE_ID}|${TABLE_NAME}"; then
        echo -e "${GREEN}存在${NC}"
    else
        echo -e "${YELLOW}未找到 (PostUp 可能还未执行)${NC}"
    fi

    # 检查 iptables
    echo -n "  iptables MASQUERADE: "
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
        echo -e "${GREEN}存在${NC}"
    else
        echo -e "${YELLOW}未找到 (PostUp 可能还未执行)${NC}"
    fi

    # 检查 wg-api (通过 wireguard 容器网络命名空间访问)
    echo -n "  wg-api (${API_PORT}): "
    if docker exec wireguard curl -sf -m 3 "http://127.0.0.1:${API_PORT}" \
         -H "Content-Type: application/json" \
         -d '{"jsonrpc":"2.0","method":"GetDeviceInfo","params":{}}' 2>/dev/null | grep -q "device"; then
        echo -e "${GREEN}正常${NC}"
    else
        echo -e "${YELLOW}无响应 (可能还在启动)${NC}"
    fi

    # 检查 wg-gen-web
    echo -n "  wg-gen-web (${WEB_PORT}): "
    if curl -sf -m 3 "http://127.0.0.1:${WEB_PORT}" -o /dev/null; then
        echo -e "${GREEN}正常${NC}"
    else
        echo -e "${YELLOW}无响应 (可能还在启动)${NC}"
    fi

    # 检查 phantun（如启用）
    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        echo -n "  phantun (${PHANTUN_PORT}/tcp): "
        if docker ps | grep -q "phantun"; then
            echo -e "${GREEN}运行中${NC}"
        else
            echo -e "${YELLOW}未运行${NC}"
        fi
    fi

    # 检查 dnscrypt（如启用）
    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        echo -n "  dnscrypt (${DNSCRYPT_PORT}/udp+tcp): "
        if docker ps | grep -q "dnscrypt"; then
            echo -e "${GREEN}运行中${NC}"
        else
            echo -e "${YELLOW}未运行${NC}"
        fi
    fi

    echo ""
    if $ok; then
        echo -e "${GREEN}============================================="
        echo "  部署完成!"
        echo "=============================================${NC}"
    else
        echo -e "${RED}============================================="
        echo "  部署完成，但部分检查未通过"
        echo "=============================================${NC}"
    fi

    echo ""
    echo "  访问地址:"
    echo "    Web UI: http://$(hostname -I | awk '{print $1}'):${WEB_PORT}"
    echo "    wg-api: http://127.0.0.1:${API_PORT}"
    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        echo ""
        echo "  Phantun 已启用:"
        echo "    TCP 端口: ${PHANTUN_PORT} (fake TCP -> UDP ${WG_PORT})"
        echo "    客户端命令: phantun_client --local 127.0.0.1:${WG_PORT} --remote <服务器IP>:${PHANTUN_PORT} --ipv4-only"
    fi
    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        echo ""
        echo "  DNSCrypt 已启用:"
        echo "    Provider: ${DNSCRYPT_NAME}"
        echo "    连接地址: ${WG_SERVER_IP}:${DNSCRYPT_PORT}"
        echo "    通过 WG 隧道连接后，dnscrypt-proxy 配置服务器为: ${WG_SERVER_IP}:${DNSCRYPT_PORT}"
    fi
    echo ""
    echo "  配置文件:"
    echo "    wg0.conf:   ${DEPLOY_DIR}/wireguard/config/wg0.conf"
    echo "    server.json: ${DEPLOY_DIR}/wireguard/config/server.json"
    echo ""
    echo "  客户端配置请通过 Web UI 下载或扫描 QR 码"
    echo ""
    echo "  日志查看:"
    echo "    docker logs wireguard"
    echo "    docker logs wg-api"
    echo "    docker logs wg-gen-web"
    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        echo "    docker logs phantun"
    fi
    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        echo "    docker logs dnscrypt"
    fi
    echo ""

}

# ========================= 显示二维码 =========================
show_download_info() {
    local target_dir="$1"

    echo ""
    echo "  请通过以下链接下载 Docker 镜像，或扫描下方二维码："
    echo ""
    echo "    百度网盘: https://pan.baidu.com/s/1etOiZv-lxH7ScECAdvIo7A"
    echo "    提取码: xnqu"
    echo ""
    echo "  或扫描以下二维码："
    echo ""

    local qr_url="https://pan.baidu.com/s/1etOiZv-lxH7ScECAdvIo7A?pwd=xnqu"

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 -s 3 -m 2 "$qr_url"
    else
        apt-get update
        apt-get install -y qrencode 2>/dev/null && {
            qrencode -t ANSIUTF8 -s 3 -m 2 "$qr_url"
        } || {
            echo "    二维码图片: https://download.0573zzz.dpdns.org/wg/baidu.png"
        }
    fi

    echo ""
    if [ "${PHANTUN_ENABLE:-false}" = "true" ]; then
        echo "  下载后，将 wg-api.tar、wg-gen-web.tar、one-step-wg.tar 和 phantun.tar 放到："
    else
        echo "  下载后，将 wg-api.tar、wg-gen-web.tar 和 one-step-wg.tar 放到："
    fi
    echo "    ${target_dir}"
    echo ""
}

# ========================= 镜像加载 =========================
load_images() {
    log_step "检查 Docker 镜像..."

    local missing_images=()

    # 检查已有镜像
    if docker image inspect "james/wg-api:latest" &>/dev/null; then
        log_info "james/wg-api:latest 已存在"
    else
        missing_images+=("james/wg-api:latest|wg-api.tar")
    fi

    if docker image inspect "wg-gen-web:0.0.2" &>/dev/null; then
        log_info "wg-gen-web:0.0.2 已存在"
    else
        missing_images+=("wg-gen-web:0.0.2|wg-gen-web.tar")
    fi

    if docker image inspect "one-step-wg:0.0.3" &>/dev/null; then
        log_info "one-step-wg:0.0.3 已存在"
    else
        missing_images+=("one-step-wg:0.0.3|one-step-wg.tar")
    fi

    if [ "${PHANTUN_ENABLE}" = "true" ]; then
        if docker image inspect "zcb617/phantun:0.8.1" &>/dev/null; then
            log_info "zcb617/phantun:0.8.1 已存在"
        else
            missing_images+=("zcb617/phantun:0.8.1|phantun.tar")
        fi
    fi

    # 全部存在，直接返回
    if [ ${#missing_images[@]} -eq 0 ]; then
        return 0
    fi

    # 尝试从本地 tar 加载
    local still_missing_after_tar=()
    for entry in "${missing_images[@]}"; do
        local tag="${entry%%|*}"
        local tar="${entry##*|}"
        if [ -f "${IMAGE_DIR}/${tar}" ]; then
            log_info "发现 ${IMAGE_DIR}/${tar}，正在加载..."
            docker load -i "${IMAGE_DIR}/${tar}"
            if ! docker image inspect "$tag" &>/dev/null; then
                log_error "加载 $tar 失败"
                exit 1
            fi
        else
            still_missing_after_tar+=("$entry")
        fi
    done

    # 检查是否还有缺失
    local still_missing=()
    for entry in "${still_missing_after_tar[@]}"; do
        local tag="${entry%%|*}"
        local tar="${entry##*|}"
        if ! docker image inspect "$tag" &>/dev/null; then
            still_missing+=("$tar")
        fi
    done

    if [ ${#still_missing[@]} -eq 0 ]; then
        return 0
    fi

    # 还有缺失，尝试 docker pull
    log_warn "无法通过本地 tar 获取以下镜像: ${still_missing[*]}"
    log_info "尝试从 Docker Hub 拉取..."

    if timeout 5 bash -c 'echo >/dev/tcp/registry-1.docker.io/443' 2>/dev/null; then
        for tar in "${still_missing[@]}"; do
            local tag=""
            case "$tar" in
                wg-api.tar) tag="james/wg-api:latest" ;;
                wg-gen-web.tar) tag="wg-gen-web:0.0.2" ;;
                one-step-wg.tar) tag="one-step-wg:0.0.3" ;;
                phantun.tar) tag="zcb617/phantun:0.8.1" ;;
            esac
            log_info "正在拉取 $tag ..."
            docker pull "$tag" || {
                log_error "拉取 $tag 失败"
                echo ""
                show_download_info "${IMAGE_DIR}"
                exit 1
            }
        done
    else
        log_error "无法连接 Docker Hub (registry-1.docker.io:443)"
        show_download_info "${IMAGE_DIR}"
        exit 1
    fi
}

# ========================= 主流程 =========================
main() {
    # setup.sh 所在目录（用于查找同目录下的 uninstall.sh）
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    check_root
    check_os
    interactive_setup

    log_step "检查 Docker..."
    check_docker

    load_images

    log_step "初始化路由表..."
    setup_rt_tables

    log_step "设置宿主机 sysctl..."
    setup_host_sysctl

    log_step "清理旧状态（避免重复启动冲突）..."
    if [ -x "${SCRIPT_DIR}/uninstall.sh" ]; then
        log_info "执行卸载脚本..."
        bash -x "${SCRIPT_DIR}/uninstall.sh" --force
    else
        log_warn "未找到卸载脚本，尝试直接停止容器..."
        cd "$DEPLOY_DIR" && $COMPOSE_CMD down -v --remove-orphans 2>/dev/null || true
        ip link del wg0 2>/dev/null || true
    fi

    log_step "生成配置文件..."
    mkdir -p "${DEPLOY_DIR}"

    # 清理旧配置（避免旧的 wg-gen-web 数据干扰）
    rm -f "${DEPLOY_DIR}/wireguard/config/wg0.conf" 2>/dev/null
    rm -f "${DEPLOY_DIR}/wireguard/config/server.json" 2>/dev/null
    rm -f "${DEPLOY_DIR}/wireguard/config/peer1.json" 2>/dev/null
    # 清理旧的 UUID 客户端配置文件（可能有 .json 后缀，也可能没有）
    for f in "${DEPLOY_DIR}/wireguard/config/"*; do
        [ -f "$f" ] || continue
        local bn; bn=$(basename "$f")
        # 保留已知非客户端文件：目录、.conf、.sh、隐藏文件、server.json
        case "$bn" in
            server.json|*.conf|*.sh|.[^.]*|wg_confs|up.d|pre-down.d|templates|coredns|server)
                continue
                ;;
        esac
        # 其余都删（包括 .json 后缀的 UUID 文件和无后缀的 UUID 文件）
        rm -f "$f"
    done
    rm -rf "${DEPLOY_DIR}/wireguard/config/wg_confs" 2>/dev/null
    rm -rf "${DEPLOY_DIR}/wireguard/config/peer1" 2>/dev/null

    generate_wg_configs
    generate_up_script
    generate_down_script
    generate_docker_compose

    # DNSCrypt 首次初始化（生成密钥）
    if [ "${DNSCRYPT_ENABLE}" = "true" ]; then
        local dnscrypt_keys="${DEPLOY_DIR}/dnscrypt/keys"
        mkdir -p "${dnscrypt_keys}"
        if [ ! -f "${dnscrypt_keys}/provider_name" ]; then
            log_step "初始化 DNSCrypt 密钥..."
            docker run --rm \
                -v "${dnscrypt_keys}:/opt/encrypted-dns/etc/keys" \
                jedisct1/dnscrypt-server:latest \
                init -N "${DNSCRYPT_NAME}" -E "${WG_SERVER_IP}:${DNSCRYPT_PORT}"
            log_info "DNSCrypt 密钥已生成: ${dnscrypt_keys}"
        else
            log_info "DNSCrypt 密钥已存在，跳过初始化"
        fi
    fi

    start_services

    sleep 3
    verify_deployment
}

main "$@"
