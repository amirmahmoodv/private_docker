# Open Docker Registry + Caddy front door, in ONE image, for RunFlare.
#
#   Public traffic ->  Caddy (:8080)  ->  Registry (127.0.0.1:5000)
#
# Caddy adds: access logging, IP allowlist, and domain allowlist.
# Both processes are supervised so the container stays healthy.

# 1) Grab the prebuilt Caddy binary
FROM caddy:2 AS caddy

# 2) Final image is the registry, plus Caddy + a tiny supervisor
FROM registry:2

RUN apk add --no-cache supervisor

COPY --from=caddy /usr/bin/caddy /usr/bin/caddy

COPY config/config.yml /etc/docker/registry/config.yml
COPY Caddyfile         /etc/caddy/Caddyfile
COPY supervisord.conf  /etc/supervisord.conf

# Caddy is the public port on RunFlare (NOT 5000 anymore)
EXPOSE 8080

# Persisted data. Attach a RunFlare Disk to this exact mount path.
VOLUME ["/var/lib/registry"]

ENTRYPOINT ["supervisord", "-c", "/etc/supervisord.conf"]
