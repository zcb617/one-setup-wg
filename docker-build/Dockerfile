FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. 先用 http 清华源快速安装 ca-certificates
RUN rm -f /etc/apt/sources.list.d/ubuntu.sources && \
    cat > /etc/apt/sources.list.d/ubuntu.sources << 'MIRROR'
Types: deb
URIs: http://mirrors.tuna.tsinghua.edu.cn/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
MIRROR
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 2. 切回 https 清华源 + 官方 security 源
RUN cat > /etc/apt/sources.list.d/ubuntu.sources << 'MIRROR'
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
MIRROR

# 3. 安装 WireGuard 及所需工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wireguard \
        iptables \
        iproute2 \
        inotify-tools \
        curl && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /etc/wireguard
EXPOSE 51820/udp

ENTRYPOINT ["/entrypoint.sh"]
