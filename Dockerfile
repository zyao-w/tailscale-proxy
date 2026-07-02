FROM jc21/nginx-proxy-manager:latest

# NPM base is Debian; install tailscale via official script
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates iptables \
 && curl -fsSL https://tailscale.com/install.sh | sh \
 && mkdir -p /var/lib/tailscale \
 && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

# NPM ports
EXPOSE 80 81 443

CMD ["/start.sh"]
