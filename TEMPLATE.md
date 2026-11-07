# Laya v0.4 Decision Engine API (Jev-Compatible): Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Laya v0.4 Decision Engine API (Jev-Compatible)** (46 chars; version label per the 0.x rule) |
| Description | Self-hosted Laya API: typed choice, score and yes/no decisions on CPU. (70 chars) |
| Category | AI/ML |
| Tags | laya, decision-engine, classification, routing, guardrails, jev, cpu-inference, pytorch, huggingface, api |
| Icon | `https://cdn.jsdelivr.net/gh/NandhaKishorM/laya@v0.4.28/assets/logo-mark.svg` (200, image/svg+xml; upstream's own mark at the release tag) |
| Repo | `baranberkay96/laya-railway`, service root `/services/laya` |
| Expected template code | `laya-v04-decision-engine-api-jev-compati` (guess; the README button is rewritten by `ship.py finish`) |

The description is delivered as written: the service is a self-hosted `laya-serve`, answers `choice`, `score` and `noul` (yes/no) questions, and runs on CPU only.

## Base market template

- **`laya`** ("Laya | Self-Hosted Jev-Compatible Decision API", two-workspaces, created 2026-09-22, 1 active project, 7 projects total). Image `ghcr.io/two-workspaces/laya:cec82db`; its repo has no licence, so it was read for ideas only. What it does: replaces upstream's `laya-serve` with its own ~220-line FastAPI server (`/v1/systemone`, `/v1/models`, `/health`), installs laya 0.4.27 with version pins but no hashes, bakes `english` and `multilingual` into the image at revision `1c5edc17` (same weight files as today's reviewed revision), requires `LAYA_API_KEY` (`secret(32)`), sizes threads from the cgroup quota, binds an empty host, restart `ON_FAILURE` × 10, healthcheck timeout via `RAILWAY_HEALTHCHECK_TIMEOUT_SEC=600`, no volume.
- Kept from its approach (re-implemented independently): mandatory generated key, both general checkpoints loaded at start, CPU-quota thread sizing (also our STANDARD lesson 15), dual-stack listener (verified in uvicorn/asyncio source).
- No upstream-published image exists (upstream's `docker.yml` only builds and tests), so this template builds from PyPI with a hash lock.

## Pinned versions

| Component | Pin | Released | Checked |
|---|---|---|---|
| Laya | `laya==0.4.28` (PyPI wheel `sha256:ad54941b…`, identical to the GitHub release asset and to tag `v0.4.28` → `634f80d9`) | 2026-11-07 | 2026-11-07 |
| PyTorch | `torch==2.14.0+cpu` from the PyTorch CPU index (`sha256:673dbf5c…`), the version upstream's Dockerfile pins | 2026 | 2026-11-07 |
| Python deps | 47 more packages, all hash-pinned in `services/laya/requirements.txt` (transformers 5.22.2, huggingface-hub 2.4.0, vegaml 0.15.0, fastapi 0.162.1, uvicorn 0.54.0, …), resolved with `exclude-newer` = laya's PyPI upload time | up to 2026-11-07 | 2026-11-07 |
| Base image | `python:3.11.18-slim-trixie@sha256:65bd3d9f…70f3fd79` (upstream uses `python:3.11-slim-trixie`) | 2026-11-05 | 2026-11-07 |
| Checkpoints | `convaiinnovations/laya` at `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851` (laya 0.4.28 `PINNED_REVISIONS`), SHA-256 digests in `services/laya/reviewed-digests.json` | 2026-09-24 | 2026-11-07 |

Nothing is installed from a vendor apt repository (lesson 27); pip retries downloads (`--retries 10`).

## Architecture

```
 client ── HTTPS (Railway edge) ──► :8080 laya-serve (uvicorn, 1 worker; IPv4 + IPv6)
 other Railway service ── http://laya.railway.internal:8080 ──┘   Authorization: Bearer LAYA_API_KEY
            ┌──────────────────────────────────────────────────────────────────────┐
            │ Laya (Dockerfile in services/laya)                                    │
            │ Railway init (PID 1) → railway-entrypoint (root)                      │
            │   key check · LAYA_PORT=PORT · LAYA_HOST="" · threads from cpu.max ≤ 8 │
            │   HF_HOME=/data/huggingface (chown once) · digests for reviewed rev   │
            │   → setpriv laya (10001) → laya_railway.py (vega lane off, interop 1) │
            │   → laya.serve.main(): preload english + multilingual, then listen    │
            │ volume /data: Hugging Face cache (~1.5 GB default, ~2.4 GB all three)  │
            └──────────────────────────────────────────────────────────────────────┘
```

## Design decisions

### Upstream's server, unchanged
`laya-serve` (`laya.serve.main`) already has bearer auth (`LAYA_API_KEY`, constant-time compare, `/docs` and OpenAPI switched off when a key is set), an open liveness-only `/health`, request limits (2 MiB bodies, 64 questions, 50,000-character states, 16 admitted requests then 503, 10 s body read timeout), batch and route endpoints and the Jev wire format. So no proxy in front: the template adds only what laya-serve has no variable for, in `laya_railway.py` (see below), and ends in `laya.serve.main()`.

### Auth
`LAYA_API_KEY` = `${{secret(48, alphanumeric)}}`. The entrypoint refuses to start when it is empty, shorter than 24 characters or contains characters outside `A-Za-z0-9._~+/=-`, because laya-serve without a key serves everything unauthenticated. `GET /health` stays open with `{"status":"ok"}` only (Railway's healthcheck); with the key it returns loaded checkpoints, revisions and device. Jev clients use the public URL as base URL and the key as API key.

### Listener
laya-serve runs uvicorn with one worker, which calls `asyncio.create_server(host=LAYA_HOST)`. `::` would be IPv6-only (lesson 2) and `0.0.0.0` IPv4-only (lesson 14). The entrypoint exports `LAYA_HOST=""`, which asyncio turns into one IPv4 and one IPv6 socket (checked in uvicorn 0.54.0 / CPython source and with a standalone asyncio test: `""` → both families accept; `0.0.0.0` → IPv6 refused; `::` → IPv4 refused). `LAYA_PORT` is set from `PORT` (lesson 1).

### Default checkpoints
`LAYA_MODELS=english,multilingual`: the two checkpoints automatic routing chooses between, which is upstream's production recommendation ("preload only the specific checkpoints you serve") and the default of its MCP server. English text goes to `english` (ModernBERT-large, 421M, 512 tokens; upstream 0.82 vs 0.71 on English), everything else to `multilingual` (mmBERT-base, 322M, 1,024 tokens). `typed-decisions` loads only on request. Memory ≈ 3.7 GB resident (estimate: bf16 files of 843 MB and 644 MB run as fp32 on CPU, plus ~0.5 GB runtime); a lean profile (`LAYA_MODELS=multilingual` plus `"model": "multilingual"` in requests, optionally `LAYA_MAX_LOADED=1` as a hard cap) is documented at ≈ 2 GB. `LAYA_MODELS` only controls the preload: routing loads the other checkpoint on demand.

### Vega lane off by default
laya 0.4.28 installs vegaml as a core dependency, and its Router then routes states estimated past 8,192 tokens (or `"model": "vega"`) to a 0.8B decoder reader that is downloaded and built on first use (upstream: 2-4 GB RAM, ~5× encoder latency; more on CPU, while the single inference worker is busy). On a CPU service that silently adds memory, volume space and minute-long requests, so `laya_railway.py` installs a `Router` subclass that defaults `vega=False` (upstream's documented switch, `docs/routing.md`) before `laya.serve.main()` runs; `build_router` resolves `Router` at call time. `TEMPLATE_VEGA_LANE=auto` restores upstream behaviour. The Dockerfile's `--self-test` builds the server's Router both ways (no weights) and fails the build if the switch stops working.

### Checkpoint supply chain
`LAYA_REVISION=reviewed` makes every built-in load use laya's reviewed commit of `convaiinnovations/laya`. With that revision, no `LAYA_SHA256_DIGESTS` of the user's own and no `LAYA_EXTRA_MODELS`, the entrypoint exports the nested digest map from `reviewed-digests.json` (4 files per checkpoint, all except `tokenizer/tokenizer_config.json`, which laya may rewrite, per `docs/security.md`). A tampered or changed file stops the preload at startup with a clear `SHA-256 mismatch` error. `TEMPLATE_VERIFY_DIGESTS=false` turns it off. The self-test fails the build if a laya upgrade moves `PINNED_REVISIONS` away from the revision the digests were made for.

### Threads
`LAYA_THREADS`, `OMP_NUM_THREADS` and `MKL_NUM_THREADS` = floor(cgroup `cpu.max` quota), capped at 8 (lesson 15; upstream's laptop sweep found the best latency at about the physical core count); no quota visible → visible CPUs, capped at 8. `LAYA_THREADS` overrides. Inter-op threads are pinned to 1 (upstream's benchmark recommendation; `TEMPLATE_INTEROP_THREADS`).

### Cache on the volume
`HF_HOME=${RAILWAY_VOLUME_MOUNT_PATH}/huggingface` (volume `/data`). A fresh volume is root-owned; the entrypoint re-owns the cache to `laya` only when its top directory is not already owned by it, then drops privileges with `setpriv` (keeps the working directory, lesson 4). The image carries no weights: builds stay small and fast, restarts read from the volume. Weights are downloaded once per volume; `HF_HUB_OFFLINE=1` after the first boot removes the Hub from later starts.

### Things deliberately left out
- A reverse proxy (laya-serve's own auth and limits suffice; no second process to supervise).
- Baking weights into the image (+1.5 GB per image, re-downloaded on every user rebuild; the volume covers restarts).
- `LAYA_AUTO_TASK`, `LAYA_EXTRA_MODELS`, `LAYA_MAX_CONCURRENT`, `LAYA_TOURNAMENT_GROUP`, `LAYA_IDLE_UNLOAD_SECONDS` as template variables: documented, addable by the user, defaults are upstream's.
- Replicas: one forward pass at a time per process and a volume per service; scale vertically or add a second service.

## Services

### Laya

| Setting | Value |
|---|---|
| Source | repo `baranberkay96/laya-railway`, root `/services/laya` (Dockerfile) |
| Start command | none (image entrypoint `/usr/local/bin/railway-entrypoint`) |
| Healthcheck | `/health` on `PORT=8080`, timeout 900 s (first boot downloads ~1.5 GB, verifies and loads before listening) |
| Public domain | yes, target port 8080 |
| TCP proxy | none |
| Volume | `/data` (Hugging Face cache) |
| Restart policy | ALWAYS (no max retries) |
| Replicas | 1 |

Files in `services/laya/`:
- `Dockerfile`: digest-pinned Python 3.11 slim, venv at `/opt/venv`, torch from the CPU index and everything else from PyPI with `--require-hashes --no-deps --only-binary=:all:`, `pip check`, CPU-torch assertion, user `laya` (10001), `bash -n` of the entrypoint and `laya_railway.py --self-test` at build. No `VOLUME`, no `USER` (the entrypoint drops privileges).
- `railway-entrypoint.sh` (bash): key check, listener, threads, cache ownership and free-space log, digests, memory hint against cgroup `memory.max`, `exec setpriv … python laya_railway.py`.
- `laya_railway.py`: vega switch, inter-op threads, `laya.serve.main()`; `--self-test` for the build.
- `requirements-torch.txt`, `requirements.txt`: hash locks; `lock/pyproject.toml` + `lock/split_requirements.py` regenerate them.
- `reviewed-digests.json`: SHA-256 per file per checkpoint at the reviewed revision.

### Variables

| Variable | Default | Notes |
|---|---|---|
| `LAYA_API_KEY` | `${{secret(48, "a-zA-Z0-9")}}` | Bearer key; required by the entrypoint (24+ chars). |
| `PORT` | `8080` | laya-serve port, healthcheck and domain target. |
| `LAYA_MODELS` | `english,multilingual` | Preloaded checkpoints. Empty means all three (laya-serve semantics). |
| `LAYA_DEFAULT_MODEL` | empty | Fallback for text with no language evidence (upstream: `multilingual`). |
| `LAYA_MAX_LOADED` | empty | Resident cap for on-demand loads (upstream: 2). |
| `LAYA_REVISION` | `reviewed` | Checkpoint revision; must be cleared for `LAYA_EXTRA_MODELS` from other repos. |
| `TEMPLATE_VERIFY_DIGESTS` | `true` | Built-in digests for the reviewed revision. |
| `TEMPLATE_VEGA_LANE` | `off` | `auto` = upstream's vega lane. |
| `LAYA_THREADS` | empty | Empty = CPU quota, max 8. |
| `LAYA_JEV_STRICT` | `0` | `1` = strict Jev response shape. |
| `LAYA_LOG_LEVEL` | `info` | uvicorn level. |
| `HF_TOKEN` | empty | Optional, only against Hub rate limits. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `20` | Grace period for in-flight requests. |

Fixed in the image: `LAYA_DEVICE=cpu`, `TORCH_DISABLE_NATIVE_JIT=1`, `TOKENIZERS_PARALLELISM=false`, `HF_HUB_DISABLE_TELEMETRY=1`, `HF_HUB_DISABLE_PROGRESS_BARS=1`. No required user inputs.

## First use

1. Deploy; watch the logs for `model cache /data/huggingface`, `checkpoint digests: SHA-256 … is checked`, the thread line and uvicorn's `Application startup complete`. First boot takes a few minutes.
2. Copy `LAYA_API_KEY` from Variables. `curl https://{domain}/health` → `{"status":"ok"}`; with `-H "Authorization: Bearer {key}"` it lists `"loaded": ["english", "multilingual"]` and the revisions.
3. Send the README's `curl` request to `/v1/systemone`.

## Improvements over market templates

1. **Upstream's own server, current release**: laya-serve 0.4.28 unchanged instead of a replacement server on 0.4.27, so `/v1/systemone/batch`, `/v1/route`, authenticated health details, upstream's request limits and hardening, `LAYA_JEV_STRICT`, extra checkpoints and every documented variable work as upstream describes.
2. **Hash-locked build**: all 48 Python packages pinned by SHA-256 and installed as wheels only, torch from the CPU index only; the market template pins versions without hashes.
3. **Checkpoint integrity**: laya's reviewed revision plus SHA-256 verification of every parsed checkpoint file before loading, using upstream's own mechanism; build fails if the pin and the digests drift apart.
4. **Weights on a volume**: smaller image and faster builds; restarts read from disk; `typed-decisions` and extra checkpoints can be added without rebuilding.
5. **Vega lane under control**: a long state cannot silently pull a 0.8B reader into a CPU service; one variable turns it on.
6. **Railway fit**: healthcheck timeout in the template (900 s), restart ALWAYS, `PORT`-driven listener on IPv4 and IPv6, threads from the CPU quota, non-root runtime, memory warning when the limit is below what `LAYA_MODELS` needs, drain period for redeploys.
7. **Documentation**: private-network URL and key references, Jev client settings, model/memory trade-offs with upstream's measured numbers, upgrade procedure.

## Scaling

Vertical only. Latency per question scales with CPU (threads follow the quota up to 8; set `LAYA_THREADS` higher on large plans and measure). Memory scales with resident checkpoints. One replica (volume). For more throughput, duplicate the service (each needs its own volume and downloads its own weights) and balance in the client.

## Resource estimate

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month. Measured in the 2026-11-07 deploy test: 5.0 GB RAM after the first English and Turkish requests (both checkpoints resident), CPU ≈ 0.2 vCPU while answering; six requests incl. health took 3.4 s end to end. Other rows are estimates.

| Profile | RAM | CPU (avg) | Volume | $/month |
|---|---|---|---|---|
| Idle, default (`english` + `multilingual` resident) | ~5 GB (measured) | ~0.01 vCPU | 1.6 GB | ≈ $50 |
| Typical (~10k questions/day, mixed languages) | ~5 GB | ~0.2 vCPU | 1.6 GB | ≈ $55 |
| Busy (~1 English question/s sustained) | ~5 GB | ~3-5 vCPU | 1.6 GB | ≈ $110-150 |
| Lean (`LAYA_MODELS=multilingual`, clients pin `multilingual`, idle) | ~2 GB | ~0.01 vCPU | 0.7 GB | ≈ $20 |

CPU cost per question from upstream's 4-core benchmark: ~0.6 s × 4 cores on `english`, ~0.2 s × 4 on `multilingual`. Expected latency on Railway: roughly 0.3-0.8 s per question on `english` and 0.1-0.3 s on `multilingual`, depending on the CPU share the service gets (unverified). Minimum plan: **Hobby** (Trial's 1 GB per service cannot hold one checkpoint; the default volume use of ~1.6 GB, ~2.5 GB with `typed-decisions`, fits Hobby's 5 GB volume).

## Upgrading

1. Edit `services/laya/lock/pyproject.toml` (`laya[serve]==X`, `torch==Y`, `exclude-newer` = the new laya upload time) and regenerate the locks with the three commands in its header.
2. Set `PIN_LAYA` in the Dockerfile. If `laya.revisions.PINNED_REVISIONS["convaiinnovations/laya"]` changed, set `PIN_REVIEWED_REVISION` and recompute `reviewed-digests.json` at that revision (small files: download and `shasum -a 256`; `model.safetensors`: the Hub LFS oid). The build's self-test enforces this.
3. Re-check upstream's Dockerfile (torch version, env), `laya/serve.py` (variables, `build_router` still importing `Router` at call time) and the release notes; rename the listing when the minor version changes (v0.5).

## Verification checklist

- [ ] Build: both pip steps succeed, `pip check` passes, `torch 2.14.0+cpu CPU` printed, `[laya-railway] self-test ok: laya 0.4.28, reviewed revision 55cf4c4…`.
- [ ] Deploy logs: thread line shows the quota (≤ 8), `checkpoint digests: SHA-256 …`, no memory warning on Hobby, uvicorn startup within the 900 s healthcheck window; note first-boot duration and the time to healthy on a restart.
- [ ] `GET /health` without key → 200 `{"status":"ok"}`; with key → `loaded` = english, multilingual and `revisions` = `55cf4c4e…`; `/docs` and `/openapi.json` → 404.
- [ ] `POST /v1/systemone` without key / wrong key → 401; README example with key → 200, `department.choice` = `billing`, `refund.noul` high, `routing.model` = `english`; a German or Hindi state → `routing.model` = `multilingual`.
- [ ] `POST /v1/systemone/batch` with 2 states → 2 results; `POST /v1/route` → routing only.
- [ ] Private network: from another service, `curl http://laya.railway.internal:8080/health` succeeds (IPv6) and the healthcheck succeeded (IPv4).
- [ ] Memory after warm-up (Railway metrics) and latency of the README request (record both in the report).
- [ ] A ~40,000-character state with `TEMPLATE_VEGA_LANE=off` answers on an encoder (`routing.model` english/multilingual, `usage.truncated` true) and RAM does not jump.
- [ ] Redeploy: no re-download (logs show no fetch, healthy in under a minute), volume use ~1.6 GB.
- [ ] `LAYA_API_KEY` cleared → deployment fails with the key error, no unauthenticated server.

## Open questions

- **Not built or run locally** (no Docker by instruction). The lock files resolve for linux/x86_64 CPython 3.11 (uv dry-run), the scripts pass `bash -n`/shellcheck, the entrypoint logic was exercised with a stub launcher and the vega switch against a fake `laya` package; the real build and first boot are untested.
- **Memory and latency are estimates** from file sizes and upstream's benchmarks, not measured on Railway.
- **`setpriv` and volume ownership** on Railway's runtime: expected to work (root in the container with SETUID/SETGID, as other packages here rely on), not observed for this image.
- **Railway private DNS and the empty-host listener**: the two-socket bind is verified locally; IPv6 private traffic on Railway not yet observed.
- **Hugging Face availability at first boot**: Hub rate limits on shared egress IPs could slow the first download; `HF_TOKEN` helps. Restarts still contact the Hub to resolve the revision unless `HF_HUB_OFFLINE=1`.
- **Dependency drift risk**: transformers 5.22.2 and huggingface-hub 2.4.0 are what laya's release CI would have resolved on 2026-11-07, but upstream does not publish a lock; a behaviour regression would only show at runtime.
- **Upstream pace**: laya releases almost daily (0.4.24 to 0.4.28 in three days). Bump deliberately with the upgrade steps; the self-test guards the two couplings this template has (reviewed revision, `build_router` constructing `laya.router.Router`).
