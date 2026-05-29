FROM debian:bookworm-slim

ARG XRAY_VERSION=v26.5.9

LABEL maintainer="G2rayXCodeLeafy" \
      description="Made By CodeLeafy"

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl wget unzip ca-certificates sudo openssl uuid-runtime tmux tzdata \
        qrencode jq bc net-tools libcap2-bin iproute2 dnsutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN wget -qO xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
    && unzip -q xray.zip -d /tmp/xray-dir \
    && mv /tmp/xray-dir/xray /usr/local/bin/xray \
    && mv /tmp/xray-dir/*.dat /usr/local/bin/ \
    && chmod +x /usr/local/bin/xray \
    && rm -rf xray.zip /tmp/xray-dir

EXPOSE 443
