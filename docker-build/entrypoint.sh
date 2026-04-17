#!/bin/bash
wg-quick up wg0 &
while true; do
    if ! ip link show wg0 &>/dev/null; then
        echo "[entrypoint] wg0 down, restarting..."
        wg-quick up wg0 &
    fi
    sleep 5
done
