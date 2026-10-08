# npm-tailscale

**English** | [繁體中文](README.zh-TW.md)

Bundle **Nginx Proxy Manager (NPM)** and **Tailscale** into a single Docker container, so NPM can reverse-proxy services on your tailnet (e.g. a home NAS, Homebridge, Home Assistant).

```
Internet ──► NPM ──► (autoforward + socat) ──► tailscaled (SOCKS5) ──► service on your tailnet
                                              (userspace networking)
```

**Experience: type a tailnet IP directly in the NPM UI, save, and it just works. No manual forwarding config.**

## Tested environment

| Component           | Version      |
| ------------------- | ------------ |
| OS                  | Ubuntu 24.04 |
| Deployment          | Docker       |
| Tailscale           | 1.102.4      |
| Nginx Proxy Manager | 2.15.1       |

The image is built `FROM jc21/nginx-proxy-manager:latest`, so a newer build may pull different versions. Pin the base image tag in the `Dockerfile` if you need reproducible builds.

---

## Why this exists

Running Tailscale in **userspace networking** mode (no `NET_ADMIN` capability, no `/dev/net/tun`) is the simplest way to run it inside a container, and the only option on many container platforms. It has two consequences:

1. `tailscaled` does not add a `100.64.0.0/10` route to the system, so a plain `curl 100.x.x.x` from any process fails.
2. The only way into the tailnet is the built-in **SOCKS5 / HTTP CONNECT proxy** of `tailscaled`.

nginx `proxy_pass` cannot use a SOCKS5 / HTTP proxy for its upstream, so a bridge is needed. This repo uses **socat** to bridge each tailnet target to a local port on `127.0.0.1`, and NPM simply proxies to it as an ordinary local service.

> Tailscale and NPM must live in the same container (same network namespace). Running them as two separate containers does not work with this approach.

---

## Files

```
npm-tailscale/
├── Dockerfile          # NPM base + tailscale + socat + autoforward
├── start.sh            # start tailscaled → tailscale up → start autoforward → exec /init
├── autoforward.sh      # watch NPM confs, auto create/clean up tailnet socat forwards
├── LICENSE
├── README.md           # English
└── README.zh-TW.md     # 繁體中文
```

---

## Deploy with Docker

### 1. Generate a Tailscale auth key

Tailscale admin → **Settings → Keys → Generate auth key**

- ✅ **Reusable**
- ❌ **Ephemeral** (must be off, otherwise the node is deleted when it goes offline)

### 2. Build the image

```sh
git clone <your-repo-url> npm-tailscale
cd npm-tailscale
docker build -t npm-tailscale .
```

### 3. Run the container

```sh
docker run -d --name npm-tailscale \
  --restart unless-stopped \
  -p 80:80 -p 81:81 -p 443:443 \
  -e TS_AUTHKEY=tskey-auth-xxxxxxxx \
  -e TS_HOSTNAME=npm-tailscale \
  -v $(pwd)/data:/data \
  -v $(pwd)/letsencrypt:/etc/letsencrypt \
  -v $(pwd)/tailscale:/var/lib/tailscale \
  npm-tailscale
```

Or with Docker Compose:

```yaml
services:
  npm-tailscale:
    build: .
    container_name: npm-tailscale
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_HOSTNAME: npm-tailscale
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
      - ./tailscale:/var/lib/tailscale
```

Volumes (all required):

| Mount path           | Purpose                                                                 |
| -------------------- | ----------------------------------------------------------------------- |
| `/data`              | NPM configuration                                                       |
| `/etc/letsencrypt`   | Let's Encrypt certificates                                              |
| `/var/lib/tailscale` | **Tailscale state. Without it the node re-registers on every restart.** |

Ports: `80` (HTTP), `81` (NPM admin UI), `443` (HTTPS).

### 4. Environment variables

| Variable        | Required | Description                                                                               |
| --------------- | -------- | ----------------------------------------------------------------------------------------- |
| `TS_AUTHKEY`    | ✅       | Auth key generated above. Keep it in a secret / `.env` file.                              |
| `TS_HOSTNAME`   |          | Node name shown in the tailnet. Default `npm-tailscale`.                                  |
| `TS_ACCEPT_DNS` |          | Set `true` to use MagicDNS names. Default `false`.                                        |
| `TS_SOCKS_PORT` |          | tailscaled SOCKS5 listen port. Default `1055`.                                            |
| `TS_FORWARDS`   |          | Optional manual forwards for testing, e.g. `18581:100.64.1.5:8581;15000:100.64.1.5:5000`. |

> A manual mapping table is **not needed**. Just enter the tailnet IP + port when creating a Proxy Host in the NPM UI; forwarding is detected and created automatically.

### 5. Create a Proxy Host in NPM (automatic tailnet forwarding)

Open `http://<host-ip>:81` on first run (default `admin@example.com` / `changeme`; you are forced to change it).

New Proxy Host:

- **Domain Names**: `homebridge.yourdomain.com`
- **Scheme**: `http`
- **Forward Hostname / IP**: the tailnet IP, e.g. `100.64.1.5` (or `nas.your-tailnet.ts.net`, requires `TS_ACCEPT_DNS=true`)
- **Forward Port**: the target service port, e.g. `8581`
- Recommended: enable **Websockets Support** and **Block Common Exploits**

A few seconds after saving, the background **autoforward** process will:

1. Detect the new config with a tailnet target
2. Allocate a local port for `100.64.1.5:8581` (e.g. `27183`, hash-based, the same target always gets the same port)
3. Start `socat 127.0.0.1:27183 → 100.64.1.5:8581` (through SOCKS5)
4. Rewrite the nginx conf generated by NPM so the upstream becomes `127.0.0.1:27183`
5. Run `nginx -s reload`

**You only work in the UI; everything else is automatic.** Deleting a Proxy Host also stops its socat process.

The SSL tab can request a new Let's Encrypt certificate as usual.

---

## Verification

Open a shell in the container (`docker exec -it npm-tailscale bash`) and run:

```sh
# 1. Tailnet is online and the target is visible
tailscale --socket=/tmp/tailscaled.sock status

# 2. Userspace networking can reach the target
tailscale --socket=/tmp/tailscaled.sock ping 100.64.1.5

# 3. SOCKS5 can open a TCP connection
curl -v --socks5-hostname localhost:1055 http://100.64.1.5:8581

# 4. Current autoforward mappings
cat /var/lib/tailscale/autoforward.state
# e.g. 100.64.1.5:8581 27183 42

# 5. Test the local port allocated by autoforward (what NPM actually connects to)
curl -v http://127.0.0.1:27183
```

**If step 5 works, NPM works.**

---

## Troubleshooting

| Symptom                                     | Cause / Fix                                                                                                                                                           |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New nodes keep appearing in Tailscale admin | `/var/lib/tailscale` volume is not mounted, state is not persisted                                                                                                    |
| NPM returns 502 Bad Gateway                 | Run the verification steps above, working backwards from step 4                                                                                                       |
| Step 2 works but 3 fails                    | Tailscale ACL blocks the traffic, or the target service only binds to `127.0.0.1` / a LAN interface                                                                   |
| Step 3 works but 5 fails                    | autoforward did not detect the conf. Check the container log for `[autoforward]` messages; make sure NPM's Forward Hostname starts with `100.` or ends with `.ts.net` |
| Hostname in the NPM UI gets changed         | It does not. autoforward only edits `/data/nginx/proxy_host/*.conf`, never the NPM database; the UI still shows the tailnet IP you entered                            |
| Node disappears after a while               | The auth key is ephemeral. Generate a non-ephemeral one                                                                                                               |
| Want to use MagicDNS names                  | Set `TS_ACCEPT_DNS=true` and enter `nas.your-tailnet.ts.net` in NPM                                                                                                   |

---

## Security notes

- **Never commit `TS_AUTHKEY`** to the repo. Use environment variables / secrets / an untracked `.env` file.
- If it leaks, revoke it immediately in Tailscale admin.
- Change the default NPM admin password immediately.
- Expose port `81` (NPM admin) only when needed, or restrict it to tailnet access.

---

## License

The files in this repository are released under the [MIT License](LICENSE).

### Third-party software

This repository contains **only scripts and a Dockerfile**. It does not include any third-party binaries. They are downloaded when you build the image and remain under their own licenses:

| Software                                                                                                                 | Source                                           | License                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| [Nginx Proxy Manager](https://github.com/NginxProxyManager/nginx-proxy-manager) (`jc21/nginx-proxy-manager`, base image) | Docker Hub                                       | MIT; the image also bundles nginx, certbot, Node.js, s6-overlay and others under their own licenses |
| [Tailscale](https://github.com/tailscale/tailscale)                                                                      | Installed via `https://tailscale.com/install.sh` | BSD-3-Clause                                                                                        |
| [socat](http://www.dest-unreach.org/socat/)                                                                              | Debian package                                   | GPL-2.0                                                                                             |
| iptables, curl, ca-certificates                                                                                          | Debian packages                                  | GPL-2.0+ / curl license / MPL-2.0 and others                                                        |

If you publish a built image (e.g. to Docker Hub or GHCR), you are responsible for complying with the licenses of all components inside it, including source-offer obligations for GPL software.

This project is not affiliated with or endorsed by Nginx Proxy Manager, Tailscale Inc. or the nginx project. "Tailscale" is a registered trademark of Tailscale Inc.
