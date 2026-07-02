# npm-tailscale

在 **Zeabur** 上把 **Nginx Proxy Manager (NPM)** 和 **Tailscale** 打包成單一 container,讓 NPM 可以反向代理到 tailnet 上的服務(例如家裡的 NAS、Homebridge、Home Assistant)。

```
公網 ──► Zeabur Gateway ──► NPM ──► (autoforward + socat) ──► tailscaled (SOCKS5) ──► 家中 NAS
                                                              (userspace networking)
```

**使用體驗:在 NPM UI 直接填 tailnet IP,存檔即通,零手動設定。**

---

## 為什麼要這樣做

Zeabur 的 container 沒有 `NET_ADMIN` capability 也沒有 `/dev/net/tun`,所以 tailscale **只能跑 userspace networking 模式**。這帶來兩個限制:

1. tailscaled 不會在系統加 `100.64.0.0/10` 的路由,任何行程直接 `curl 100.x.x.x` 都會失敗。
2. 進 tailnet 的唯一出口是 tailscaled 內建的 **SOCKS5 / HTTP CONNECT proxy**。

而 nginx 的 `proxy_pass` 不支援 upstream 走 SOCKS5 / HTTP proxy,所以中間必須有一個 bridge。這個 repo 用 **socat** 把 tailnet 的目標橋接成 `127.0.0.1` 上的本地 port,NPM 只要當作一般本機服務去代理就好。

> 用兩個 Zeabur service(tailscale + NPM 分開)是行不通的,因為兩個 container 不共用 network namespace,socat / proxy 都幫不上忙。

---

## 檔案結構

```
npm-tailscale/
├── Dockerfile          # NPM base + tailscale + socat + autoforward
├── start.sh            # 起 tailscaled → tailscale up → 起 autoforward → exec /init
├── autoforward.sh      # 監看 NPM conf,自動建立/清理 tailnet socat forward
└── README.md
```

---

## 部署步驟

### 1. 產生 Tailscale auth key

Tailscale admin → **Settings → Keys → Generate auth key**

- ✅ **Reusable**
- ❌ **Ephemeral**(一定要取消,不然節點下線會被刪)

### 2. Push 到你自己的 GitHub repo

### 3. 在 Zeabur 建立 service

- **Deploy from GitHub**,選這個 repo
- 加 volumes(缺一不可):
  | Mount path | 用途 |
  |---|---|
  | `/data` | NPM 設定 |
  | `/etc/letsencrypt` | Let's Encrypt 憑證 |
  | `/var/lib/tailscale` | **tailscale state,沒掛會不斷重登** |
- 開 ports:`80`(HTTP)、`81`(NPM 後台)、`443`(HTTPS)
- 綁 domain 到 `80` / `443`

### 4. 設定環境變數

| 變數            | 必填 | 說明                                        |
| --------------- | ---- | ------------------------------------------- |
| `TS_AUTHKEY`    | ✅   | 上面產生的 key,建議用 Zeabur secret 存      |
| `TS_HOSTNAME`   |      | 節點在 tailnet 顯示的名字,預設 `zeabur-npm` |
| `TS_ACCEPT_DNS` |      | `true` 才能用 MagicDNS 名稱,預設 `false`    |
| `TS_SOCKS_PORT` |      | tailscaled SOCKS5 監聽 port,預設 `1055`     |

> **不需要** `TS_FORWARDS` 這種手動對照表 —— 在 NPM UI 新增 Proxy Host 時直接填 tailnet IP + port,背景會自動偵測並建立轉發。

### 5. 進 NPM 建 Proxy Host(自動 tailnet 轉發)

第一次登入 `http://<zeabur-domain>:81`(預設 `admin@example.com` / `changeme`,強制改密碼)。

New Proxy Host:

- **Domain Names**:`homebridge.yourdomain.com`
- **Scheme**:`http`
- **Forward Hostname / IP**:直接填 tailnet IP,例如 `100.64.1.5`(或 `nas.你的-tailnet.ts.net`,需要設 `TS_ACCEPT_DNS=true`)
- **Forward Port**:目標服務 port,例如 `8581`
- 建議勾 **Websockets Support**、**Block Common Exploits**

按存檔後幾秒內,容器內背景的 **autoforward** 會:

1. 偵測到你新增的設定含 tailnet 目標
2. 為 `100.64.1.5:8581` 分配一個 local port(例如 `27183`,基於 hash,同目標永遠同 port)
3. 啟動 `socat 127.0.0.1:27183 → 100.64.1.5:8581`(走 SOCKS5)
4. 改寫 NPM 產生的 nginx conf,把 upstream 換成 `127.0.0.1:27183`
5. `nginx -s reload`

**你只需要在 UI 操作,其他全自動。** 刪掉 Proxy Host 也會自動停對應的 socat。

SSL 分頁可直接 Request a new SSL Certificate(Let's Encrypt)。

---

## 驗證步驟

Zeabur → 該 service → **Terminal**,依序執行:

```sh
# 1. tailnet 上線且看得到目標
tailscale --socket=/tmp/tailscaled.sock status

# 2. userspace 網路能到目標
tailscale --socket=/tmp/tailscaled.sock ping 100.64.1.5

# 3. 直接測 SOCKS5 是否能建立 TCP
curl -v --socks5-hostname localhost:1055 http://100.64.1.5:8581

# 4. 看 autoforward 目前管理的對照
cat /var/lib/tailscale/autoforward.state
# 例:100.64.1.5:8581 27183 42

# 5. 測 autoforward 分配的本地 port(NPM 實際會連的)
curl -v http://127.0.0.1:27183
```

**第 5 步通,NPM 就一定通。**

---

## 疑難排解

| 症狀                          | 原因 / 解法                                                                                                             |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Tailscale admin 一直冒新節點  | `/var/lib/tailscale` volume 沒掛,state 沒持久化                                                                         |
| NPM 502 Bad Gateway           | 進 container 跑上面「驗證步驟 4」,不通就往前推                                                                          |
| 步驟 2 通但 3 不通            | Tailscale ACL 沒放行,或 NAS 上服務只綁 `127.0.0.1` / LAN 介面                                                           |
| 步驟 3 通但 5 不通            | autoforward 沒偵測到 conf,看容器 log `[autoforward]` 訊息;確認 NPM 的 Forward Hostname 是 `100.x` 開頭或 `.ts.net` 結尾 |
| NPM UI 顯示的 hostname 被改掉 | 不會 —— autoforward 只改 `/data/nginx/proxy_host/*.conf`,不動 NPM 資料庫,UI 仍顯示你原本填的 tailnet IP                 |
| 節點過陣子自動消失            | authkey 是 ephemeral,重產一把非 ephemeral 的                                                                            |
| 想用 MagicDNS 名稱            | 設 `TS_ACCEPT_DNS=true`,NPM 內直接填 `nas.你的-tailnet.ts.net`                                                          |

---

## 安全提醒

- **`TS_AUTHKEY` 不要寫在 repo 裡**,用 Zeabur 環境變數 / secret
- 一旦外洩立刻到 Tailscale admin 撤銷
- NPM 後台預設密碼務必立即修改
- Port `81`(NPM 後台)建議只在需要時暴露,或改成僅透過 tailnet 存取

---

## 授權

MIT
