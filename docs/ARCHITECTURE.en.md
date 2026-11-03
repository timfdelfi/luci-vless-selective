# Architecture (short English version)

The full description is in [ARCHITECTURE.md](ARCHITECTURE.md) (Russian). This page is a map for contributors.

```
browser (LuCI)                    OpenWrt router
┌────────────┐  ubus/JSON-RPC  ┌──────────────────┐
│ main.js    │ ───────────────▶│ rpcd plugin      │ /usr/libexec/rpcd/vless
└────────────┘ ◀───────────────│ (bridge + ACL)   │
                               └────────┬─────────┘
                                        ▼
                               /usr/bin/vless (sh) + lib/*.sh + jq programs
                               ├─ UCI:   /etc/config/vless
                               ├─ data:  /etc/vless/*.json (0600)
                               └─ state: /var/run/vless/ (tmpfs)
                                        │ procd (init.d/vless)
                                        ▼
                               sing-box (TUN vless0, Clash API) + ip rule / nft / dnsmasq
```

## Principles

- **The backend is a CLI.** Every `vless <command>` prints JSON; the web UI only calls methods. Everything works over SSH without LuCI.
- **Only `main.js` depends on the LuCI version.**
- **Own sing-box instance.** `/etc/sing-box` and foreign `ip rule` / nft rules are never touched.

## Backend modules (`root/usr/share/vless/lib/`)

| Module | Responsibility |
| --- | --- |
| `util.sh` | helpers: `cfg`, `api` (Clash API), atomic writes, locks, job limits |
| `validate.sh` | input validators (IP, CIDR, domain, route target) |
| `settings.sh` | settings read/write (`settings_json`, `cmd_set`) |
| `discord.sh` | glue between settings and the Discord bypass |
| `cron.sh` | schedule for auto-refresh |
| `subscriptions.sh` | subscriptions and servers (add/refresh/remove/select) |
| `lifecycle.sh` | prepare / connect / disconnect / run |
| `net.sh` | routing rules, DNS, `net_up` / `net_down` |
| `selective.sh` | "selected services only" mode (nftset) |
| `probe.sh` | checks and ping |
| `status.sh` | state for the UI, selftest |

Rules: a module only declares functions; load order does not matter; a function lives in exactly one module (`tests/modules.sh` enforces this).

## Lifecycle

1. **add** → `parse.jq` turns links/subscriptions into servers, merged without resurrecting servers the user deleted.
2. **connect** → `vless prepare` (check sing-box ≥ 1.12 and `/dev/net/tun`, build `config.json` with `build.jq`, run `sing-box check` on a temp file, then swap) → procd runs `vless run` → `net_up` + `exec sing-box`.
3. **net_up** → table 100 (`default dev vless0`), `ip rule` priorities 9000–9100, IPv6 block, dnsmasq snippet. Own rules are recorded in `rule.prefs`; `net_down` removes exactly those.
4. **stop** → `net_down` removes rules, the `inet vless` nft table and the dnsmasq snippet.

## Data safety

Keys and subscription tokens live only in `/etc/vless` (0600) and `/var/run/vless`. Secrets go to subprocesses via stdin, not `argv`. All database writes are atomic (temp file with `umask 077`, then rename).

## Tests

`tests/run.sh` (parsing, config build, validators; runs the rest), `tests/backend.sh` (backend on stubs), `tests/discord.sh`, `tests/modules.sh`, `tests/mock-drift.sh`, `tests/ui/` (Playwright), `ci/check-release.sh` (release consistency).
