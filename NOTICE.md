# NOTICE: Laya Decision Engine API template

This is a community template. It is not affiliated with or endorsed by the Laya authors (Convai Innovations, NandhaKishorM/laya), TypeSafe (Jev) or Railway. "Laya" and its logo belong to their owners and are used only to name the software this template deploys.

## Software installed in the image

| Component | Source | Licence | How it is used |
|---|---|---|---|
| Laya 0.4.28 | PyPI `laya==0.4.28`, wheel `sha256:ad54941b…54d0b3e6` (identical to the GitHub release asset; package contents identical to tag `v0.4.28`), https://github.com/NandhaKishorM/laya | Apache-2.0, Convai Innovations (package metadata; LICENSE in the wheel's dist-info) | Installed unmodified; `laya-serve` (`laya.serve.main`) is the server |
| PyTorch 2.14.0+cpu | https://download.pytorch.org/whl/cpu, cp311 manylinux_2_28 x86_64, `sha256:673dbf5c…cdafa42` | Apache-2.0 AND BSD-2/3-Clause AND MIT AND others (PyPI metadata) | Installed unmodified |
| transformers 5.22.2, huggingface-hub 2.4.0, tokenizers 0.23.3, safetensors 0.8.0, hf-xet 1.8.0 | PyPI | Apache-2.0 | Installed unmodified |
| vegaml 0.15.0 | PyPI (laya core dependency) | Apache-2.0 | Installed unmodified; its lane is off by default (see TEMPLATE.md) |
| FastAPI 0.162.1, uvicorn 0.54.0, numpy 2.4.6, cryptography 50.0.2 and the rest of `services/laya/requirements.txt` (48 packages in total) | PyPI | MIT, BSD-3-Clause, Apache-2.0 and others; each licence ships in the package's `dist-info` inside the image | Installed unmodified |
| Python 3.11.18 on Debian trixie | Docker Hub `python:3.11.18-slim-trixie@sha256:65bd3d9f…70f3fd79` | PSF-2.0 (Python), Debian package licences | Base image |

## Model weights (downloaded at runtime, not redistributed)

| Checkpoint | Source | Licence |
|---|---|---|
| `english`, `multilingual`, `typed-decisions` | Hugging Face `convaiinnovations/laya` at revision `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851` (laya 0.4.28 `PINNED_REVISIONS`) | Apache-2.0 (model card) |
| vega reader (only with `TEMPLATE_VEGA_LANE=auto`) | Hugging Face `nandakishorm/vega-U` plus its backbone, loaded by vegaml | see those model cards |

The weights are fetched by Laya into the user's own Railway volume. `services/laya/reviewed-digests.json` holds SHA-256 digests we computed on 2026-11-07: the small files (`rl_agent_config.json`, `encoder/config.json`, `tokenizer/tokenizer.json`) downloaded at that revision and hashed locally, `model.safetensors` from the Hub's LFS object ids (the SHA-256 of the file), cross-checked with the `x-linked-etag` header. The multilingual `tokenizer.json` (an LFS file) matched both ways.

## What was adapted from upstream (Apache-2.0)

- From the upstream `Dockerfile` (tag `v0.4.28`): the base image line (`python:3.11-slim-trixie`), the unprivileged user UID/GID 10001, `HF_HOME` under the user's cache convention (moved to the volume here), and the runtime environment `USE_TF=0`, `USE_TORCH=1`, `TOKENIZERS_PARALLELISM=false`, `TORCH_DISABLE_NATIVE_JIT=1`, `LAYA_DEVICE=cpu`, torch 2.14.0 from the CPU index. The Dockerfile itself was written for this template (hash-locked installs instead of a source build, no ModelScope prefetch, root entrypoint that drops privileges).
- The `curl` example in README.md is modelled on upstream's `examples/docker/request.json` and `docs/http-api.md`.
- Facts about routing, memory, latency, the vega lane, the digest format and the environment variables come from upstream's `README.md`, `BENCHMARKS.md`, `docs/http-api.md`, `docs/docker.md`, `docs/routing.md`, `docs/security.md`, `laya/serve.py`, `laya/router.py`, `laya/revisions.py` and `laya/agent.py` at `v0.4.28`.

Written for this template: `services/laya/Dockerfile`, `railway-entrypoint.sh` (its cgroup CPU-quota function is reused from our own Odysseus template), `laya_railway.py`, `reviewed-digests.json`, the lock input and split script in `services/laya/lock/`, and all documentation.

## Market template reviewed

| Template / repo | Licence | Use |
|---|---|---|
| Railway template `laya` ("Laya \| Self-Hosted Jev-Compatible Decision API", image `ghcr.io/two-workspaces/laya:cec82db`) / `two-workspaces/laya` | none (all rights reserved) | Read for ideas only; no file, code or text copied. It replaces laya-serve with its own server and bakes the weights into the image. One idea seen there, binding uvicorn to an empty host for IPv4 plus IPv6, was verified independently in the uvicorn 0.54.0 and CPython 3.11 asyncio sources and with a standalone asyncio test before use. |

## Upstream sources and registries checked (2026-11-07)

- GitHub `NandhaKishorM/laya`: release `v0.4.28` (published 2026-11-07 14:44 UTC, tag object `0be2fb00…` → commit `634f80d9…`), release assets and their digests; `_upstream` copy compared file by file with the tag (serve.py, router.py, revisions.py, agent.py, Dockerfile, compose.http.yaml identical); no container image is published by upstream (its `docker.yml` workflow only builds and tests).
- PyPI JSON API: `laya` 0.4.28 files and hashes; upload times of the locked dependencies; licences of the main dependencies.
- `uv lock` / `uv export` (uv 0.11.19) for Linux x86_64 and CPython 3.11, torch from `https://download.pytorch.org/whl/cpu` only, `exclude-newer` 2026-11-07T15:00Z; a dry-run install of both lock files resolved all 48 packages as wheels.
- Docker Hub registry: `python:3.11.18-slim-trixie` index digest `sha256:65bd3d9f1d7fa268dd1909973ba7eb4bdf41f6dcf2cfbe76ba9528b170f3fd79` (amd64 `sha256:b701198c…`); Debian trixie `util-linux` (essential) provides `/usr/bin/setpriv`.
- Hugging Face API: `convaiinnovations/laya` file tree at `main` (`7b928d82…`) and at the reviewed revision `55cf4c4e…` (same weight files), the commit list, and the `nandakishorm/vega-U` file tree.
- uvicorn 0.54.0 source (`main.py`, `server.py`, `config.py`): one worker calls `loop.create_server(host=config.host, …)`; huggingface-hub environment variable documentation.
