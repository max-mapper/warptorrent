FROM alpine:3.22
ARG USQUE_VERSION=4.2.1
ARG TARGETARCH
RUN apk add --no-cache iptables ip6tables iproute2 curl jq ca-certificates
# Official usque release binary, checksum-verified.
RUN set -eu; cd /tmp; \
    f="usque_${USQUE_VERSION}_linux_${TARGETARCH}.zip"; \
    base="https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}"; \
    wget -q "$base/$f" "$base/checksums.txt"; \
    grep " $f\$" checksums.txt | sha256sum -c -; \
    unzip -q "$f" usque -d /usr/local/bin; \
    rm -f /tmp/*
COPY entrypoint.sh on-connect.sh healthcheck.sh /
ENTRYPOINT ["/entrypoint.sh"]
