FROM jc21/nginx-proxy-manager:latest

# NPM base is Debian; install tailscale via official script
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates iptables socat \
 && curl -fsSL https://tailscale.com/install.sh | sh \
 && mkdir -p /var/lib/tailscale \
 && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
COPY autoforward.sh /usr/local/bin/autoforward.sh
# strip potential CRLF (in case git autocrlf on Windows) + make executable
RUN sed -i 's/\r$//' /start.sh /usr/local/bin/autoforward.sh \
 && chmod +x /start.sh /usr/local/bin/autoforward.sh

# NPM ports
EXPOSE 80 81 443

# Override NPM's s6 entrypoint; start.sh will exec /init at the end
ENTRYPOINT ["/start.sh"]
