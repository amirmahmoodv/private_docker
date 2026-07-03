# Docker Registry on RunFlare — with access logs + IP/domain allowlisting

A self-hosted [Docker Registry](https://distribution.github.io/distribution/) (`registry:2`) fronted by [Caddy](https://caddyserver.com/), packaged as **one container** so it drops straight onto RunFlare.

```
Public traffic ──▶ Caddy :8000 ──▶ Registry 127.0.0.1:5000 ──▶ Disk /var/lib/registry
                     │
                     ├─ access log (who pulled/pushed, from which IP)
                     ├─ IP allowlist   (ALLOWED_IPS)
                     └─ domain allowlist (ALLOWED_HOSTS)
```

```
docker_registry/
├── Dockerfile          # registry + caddy + supervisor, one image
├── Caddyfile           # access log + IP/domain allowlist
├── supervisord.conf    # runs both processes, restarts on crash
├── config/config.yml   # registry config (internal, no auth)
├── docker-compose.yml  # local test
├── .env.example
└── .gitignore
```

## Why this shape

The registry itself can't restrict callers or log who connects, and **RunFlare has no built-in inbound firewall / IP allowlist** (confirmed from their docs — they give you Docker deploy, disks, domains + SSL, env vars, and a log viewer, but no per-request access control). So a small proxy in front is the only reliable way to get IP/domain allowlisting and access logs. Caddy is baked into the **same image**, so it's still a single RunFlare service.

---

## What you get

- **Access log** — Caddy writes a JSON line per request to stdout (visible in RunFlare's real-time log viewer): method, path, status, and the **real client IP**. Blocked attempts are logged too, so you have an audit trail of *who tried what*.
- **IP allowlist** — `ALLOWED_IPS` env var. Anyone not on the list gets `403`.
- **Domain allowlist** — `ALLOWED_HOSTS` env var. The registry only answers on the hostnames you list.

> On "whitelisting domains": you can restrict **which hostnames the registry answers to** (the `Host` header) via `ALLOWED_HOSTS`. You **cannot** reliably whitelist a *client's* domain — clients connect by IP, so client-side restriction is `ALLOWED_IPS`.

> To also log **usernames** (not just IPs), turn auth back on — see "Add logins" below. The Caddy access log will then include the authenticated user.

---

## 1. Test locally

```bash
docker compose up -d --build

docker pull alpine
docker tag alpine localhost:8000/alpine:test
docker push localhost:8000/alpine:test

docker compose logs -f registry     # watch the JSON access log
```

Locally `ALLOWED_IPS` is `0.0.0.0/0 ::/0` (allow all) so it won't lock you out of your own machine. Tighten it in RunFlare.

---

## 2. Deploy on RunFlare

1. **Push this folder to a Git repo** (GitHub/GitLab) — RunFlare deploys from Git.
2. **New Service → Docker / Dockerfile**, point it at your repo. RunFlare builds the `Dockerfile`.
3. **Port:** expose **`8000`** ← note: Caddy's port now, *not* 5000.

4. ### 📁 Folders to create in RunFlare (Disks)

   | Disk mount path | Required? | Purpose | Size |
   |-----------------|-----------|---------|------|
   | **`/var/lib/registry`** | ✅ **Yes** | All image blobs, layers & manifests. | 10–50 GB |

   Still the only folder you must persist. Without it, redeploys wipe your images.

5. **Environment variables** (RunFlare → Service → Env):

   | Key | Example value | Purpose |
   |-----|---------------|---------|
   | `REGISTRY_HTTP_SECRET` | `a-long-random-string` | keep uploads stable across restarts |
   | `ALLOWED_HOSTS` | `myreg.apps.runflare.com registry.example.com` | domains the registry answers on |
   | `ALLOWED_IPS` | `203.0.113.5 198.51.100.0/24` | client IPs/CIDRs allowed to connect |

   To temporarily allow every IP: `ALLOWED_IPS = 0.0.0.0/0 ::/0`.

6. **Domain:** enable a domain with one-click SSL. Put that same hostname in `ALLOWED_HOSTS`.

7. **Logs:** open RunFlare's log viewer — each pull/push (and each blocked attempt) shows up as a JSON line with the client IP.

Then:
```bash
docker tag myapp myreg.apps.runflare.com/myapp:1.0
docker push myreg.apps.runflare.com/myapp:1.0
```

---

## Important: real client IP behind RunFlare

RunFlare's ingress proxies to your container, so the direct peer Caddy sees is RunFlare's *internal* address. The real caller arrives in the `X-Forwarded-For` header. The `Caddyfile` already sets `trusted_proxies static private_ranges` so `client_ip` (used by the allowlist and the log) resolves to the **real** client.

If the allowlist ever behaves unexpectedly, check the access log: it shows both the direct remote address and the forwarded chain, so you can confirm what RunFlare is passing and adjust `trusted_proxies` if needed.

---

## Add logins (optional — so logs show usernames)

1. Generate credentials:
   ```bash
   docker run --rm httpd:2 htpasswd -Bbn myuser 'MyStrongPassword' > auth/htpasswd
   ```
2. In the `Dockerfile`, add: `COPY auth/htpasswd /auth/htpasswd`
3. In `config/config.yml`, uncomment the `auth:` block.
4. Redeploy. Now `docker login` is required, and the Caddy access log records the username per request.

---

## Notes & gotchas

- **HTTPS is mandatory** for the Docker client unless the host is in `insecure-registries`. RunFlare's domain gives you HTTPS.
- **Deleting images** frees the manifest but not the blobs until garbage collection:
  ```bash
  registry garbage-collect /etc/docker/registry/config.yml   # inside the container
  ```
- **Persist logs (optional):** point Caddy's `log` at a file under `/var/lib/registry/logs` instead of stdout if you want them kept on the Disk rather than only in RunFlare's viewer.
- **`registry:3`** exists; `registry:2` is used for maximum tooling compatibility. Bump the `FROM` when ready.
