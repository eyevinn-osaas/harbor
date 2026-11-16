# OSC patches on top of upstream Harbor (v2.15.5)

Only two one-line changes to Go sources. Everything else lives in Dockerfile.osc, osc-entrypoint.sh and osc-supervisor.sh.

| File | Change |
|---|---|
| `src/registryctl/main.go` | `Addr: os.Getenv("OSC_BIND_ADDR") + ":" + port` (was `":" + port`) |
| `src/jobservice/api/server.go` | `Addr: fmt.Sprintf("%s:%d", os.Getenv("OSC_BIND_ADDR"), port)` (was `":%d"`), plus `"os"` import |

Purpose: Harbor's config offers no bind address for these two daemons, and the container cannot rely on iptables (needs NET_ADMIN). With `OSC_BIND_ADDR=127.0.0.1` (set by the entrypoint) they listen on loopback only. Unset, behaviour is identical to upstream.

Rebasing onto a new upstream release: rebase the `osc` branch onto the release tag. If the two `Addr:` lines conflict, re-apply the change above (grep for `Addr:` in those files), then update the version pins in `Dockerfile.osc` (`HARBOR_VERSION`, `GITCOMMIT`, `REGISTRY_SRC_TAG` from the upstream Makefile, `GO_IMAGE`, `NODE_IMAGE`) and check upstream `make/photon/prepare/templates/*` for new env vars.

Core (beego `httpaddr` in app.conf) and the registry (`http.addr`) need no patch.
