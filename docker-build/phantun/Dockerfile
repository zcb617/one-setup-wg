#
# Dockerfile for phantun (fixed runtime deps)
# Based on official dndx/phantun v0.8.1 with iproute2, iptables, procps added
#

#
# Build stage
#
FROM rust:latest AS builder

COPY . /phantun
RUN cd /phantun \
  && cargo build --release \
  && strip target/release/server target/release/client \
  && install target/release/server /usr/local/bin/phantun-server \
  && install target/release/client /usr/local/bin/phantun-client

#
# Runtime stage
#
FROM debian:latest

# Install missing runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends iproute2 iptables procps && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/phantun-server /usr/local/bin/
COPY --from=builder /usr/local/bin/phantun-client /usr/local/bin/
COPY --from=builder /phantun/docker/phantun.sh /usr/local/bin/

ENV USE_IPTABLES_NFT_BACKEND=0
ENV RUST_LOG=INFO

ENTRYPOINT ["phantun.sh"]
CMD ["phantun-server", "--help"]
