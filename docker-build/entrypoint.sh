#!/bin/bash
set -e

CONF_FILE="/etc/wireguard/wg0.conf"
CONF_DIR="/etc/wireguard"
PURE_CONF="/tmp/wg0.pure.conf"
SHUTDOWN_FLAG="/tmp/wg-shutdown"

# 容器重启会复用可写层，需要清理上次优雅停止留下的标记。
rm -f "$SHUTDOWN_FLAG"

# 清理函数：容器收到 docker stop 的 SIGTERM 时执行
cleanup() {
    echo "[entrypoint] Received shutdown signal, stopping wg0..."
    touch "$SHUTDOWN_FLAG"
    wg-quick down wg0 
    # 终止后台 inotifywait 进程
    pkill -f "inotifywait.*$CONF_DIR" 
    exit 0
}
trap cleanup SIGTERM SIGINT

# 从 wg0.conf 提取纯 WireGuard 配置（只保留 wg 命令能识别的字段）
# wg 只支持: ListenPort, PrivateKey, FwMark, PublicKey, PresharedKey, AllowedIPs, Endpoint, PersistentKeepalive
extract_wg_pure_conf() {
    local src="$1"
    local dst="$2"
    awk '
    BEGIN { in_interface = 0; in_peer = 0 }
    /^\[Interface\]/ { in_interface = 1; in_peer = 0; print; next }
    /^\[Peer\]/      { in_interface = 0; in_peer = 1; print; next }
    /^\[/            { in_interface = 0; in_peer = 0; next }
    /^#/             { next }
    /^[[:space:]]*$/ { next }
    in_interface && /^[[:space:]]*(ListenPort|PrivateKey|FwMark)[[:space:]]*=/ { print; next }
    in_peer      && /^[[:space:]]*(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[[:space:]]*=/ { print; next }
    ' "$src" > "$dst"
}

# 同步配置到内核
sync_wg0() {
    if [ -f "$SHUTDOWN_FLAG" ]; then
        return
    fi
    if [ ! -f "$CONF_FILE" ]; then
        echo "[entrypoint] ${CONF_FILE} not found, skipping sync"
        return
    fi

    extract_wg_pure_conf "$CONF_FILE" "$PURE_CONF"

    if ip link show wg0 &>/dev/null; then
        echo "[entrypoint] Syncing wg0.conf to kernel..."
        if ! wg syncconf wg0 "$PURE_CONF" 2>/dev/null; then
            echo "[entrypoint] wg syncconf failed, trying wg-quick down/up..."
            wg-quick down wg0 
            wg-quick up wg0 
        fi
    else
        echo "[entrypoint] wg0 not up, starting..."
        wg-quick up wg0 
    fi
}

# 初始启动（同步当前配置到内核）
sync_wg0

# 后台线程：持续监控目录变化（监听目录比监听单个文件更可靠）
(
    while true; do
        if [ -d "$CONF_DIR" ]; then
            # -m 持续监控模式，监听目录内所有文件的变化
            inotifywait -m -e modify,close_write,moved_to --format '%f' "$CONF_DIR" 2>/dev/null | while read -r filename; do
                if [ "$filename" = "wg0.conf" ]; then
                    echo "[entrypoint] Detected wg0.conf change, syncing..."
                    sleep 1  # debounce
                    sync_wg0
                fi
            done
        fi
        # 如果 inotifywait 退出（目录不存在或被删除），等待后重试
        sleep 2
    done
) &

# 主循环：监控 wg0 接口，如果 down 了就重启
while true; do
    if [ -f "$SHUTDOWN_FLAG" ]; then
        break
    fi
    if ! ip link show wg0 &>/dev/null; then
        echo "[entrypoint] wg0 down, restarting..."
        sync_wg0
    fi
    sleep 5
done
