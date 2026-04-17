#!/usr/bin/env bash
#
# one-step-wg: WireGuard 卸载脚本
# 一键删除所有容器、配置、iptables/ip route 规则
#

set -euo pipefail

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

# ========================= 参数解析 =========================
FORCE=false
KEEP_DIR=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --keep-dir) KEEP_DIR=true ;;
    esac
done

# ========================= 确认 =========================
if [ "$FORCE" != true ]; then
    echo "============================================="
    echo "  one-step-wg: 卸载"
    echo "============================================="
    echo ""
    echo "  将删除以下内容："
    echo "    - Docker 容器: wireguard, wg-api, wg-gen-web"
    echo "    - WireGuard 接口 wg0"
    echo "    - iptables MASQUERADE / FORWARD 规则"
    echo "    - ip route 自定义路由表 (table 9999)"
    echo "    - /etc/iproute2/rt_tables.d/wg.conf"
    echo "    - 部署目录 (默认 /opt/one-step-wg)"
    echo ""
    read -rp "确认卸载? 所有配置将被删除 (yes/N): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "已取消。"
        exit 0
    fi
fi

# ========================= 读取部署配置 =========================
DEPLOY_DIR="/opt/one-step-wg"
if [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
    :
elif [ -f "./docker-compose.yml" ]; then
    DEPLOY_DIR="$(pwd)"
else
    log_warn "未找到部署目录，尝试使用默认路径: $DEPLOY_DIR"
fi

# 读取 docker-compose.yml 中的 INTERNAL_SUBNET（动态获取）
WG_SUBNET=""
if [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
    WG_SUBNET=$(grep -oP 'INTERNAL_SUBNET=\K[0-9.]+/([0-9]+)' "$DEPLOY_DIR/docker-compose.yml" 2>/dev/null || true)
fi
if [ -z "$WG_SUBNET" ]; then
    WG_SUBNET="10.8.0.0/24"
    log_warn "未能读取部署配置，使用默认网段: $WG_SUBNET"
fi

# 判断 compose 命令
if command -v docker compose &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    log_error "未找到 docker compose"
    exit 1
fi

# ========================= 停止并删除容器 =========================
log_step "停止并删除容器..."
if [ -d "$DEPLOY_DIR" ]; then
    cd "$DEPLOY_DIR"
    $COMPOSE_CMD down -v --remove-orphans 2>/dev/null || true
    log_info "容器已删除"
else
    log_info "部署目录不存在，跳过容器清理"
fi

# ========================= 删除 WireGuard 接口 =========================
log_step "检查并删除 wg0 接口..."
if ip link show wg0 &>/dev/null 2>&1; then
    ip link del wg0 2>/dev/null || true
    log_info "wg0 接口已删除"
else
    log_info "wg0 不存在"
fi

# ========================= 清理 iptables 规则 =========================
log_step "清理 iptables 规则..."
NAT_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"

iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${NAT_IFACE} -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true

log_info "iptables 规则已清理"

# ========================= 清理路由规则 =========================
log_step "清理路由规则..."
# 删除 table 9999 下的所有路由
ip route flush table 9999 2>/dev/null || true
# 删除所有指向 table 9999 的 rule
ip rule del table 9999 2>/dev/null || true

# 删除自定义路由表
rt_file="/etc/iproute2/rt_tables.d/wg.conf"
if [ -f "$rt_file" ]; then
    rm -f "$rt_file"
    log_info "已删除 $rt_file"
else
    log_info "$rt_file 不存在"
fi

# ========================= 删除部署目录 =========================
if [ "$KEEP_DIR" != true ]; then
    log_step "删除部署目录..."
    if [ -d "$DEPLOY_DIR" ]; then
        rm -rf "$DEPLOY_DIR"
        log_info "已删除 $DEPLOY_DIR"
    else
        log_info "$DEPLOY_DIR 不存在"
    fi
else
    log_info "保留部署目录 (--keep-dir)"
fi

# ========================= 完成 =========================
echo ""
echo -e "${GREEN}============================================="
echo "  卸载完成!"
echo "=============================================${NC}"
echo ""
echo "  如不再需要，可手动删除镜像："
echo "    docker rmi lscr.io/linuxserver/wireguard"
echo "    docker rmi james/wg-api"
echo "    docker rmi vx3r/wg-gen-web"
echo ""
