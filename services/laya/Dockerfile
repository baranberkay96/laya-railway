# syntax=docker/dockerfile:1
#
# Laya v0.4.28 (https://github.com/NandhaKishorM/laya, Apache-2.0) as an always-on, CPU-only
# HTTP API for Railway: laya-serve, the Jev-compatible /v1/systemone server laya ships.
#   - laya 0.4.28 from PyPI and every dependency pinned by SHA-256 (requirements*.txt),
#     torch 2.14.0 CPU wheel from the PyTorch CPU index only (no CUDA libraries)
#   - checkpoints download on first boot into the Railway volume (HF_HOME under /data),
#     pinned to laya's reviewed Hub revision and checked against SHA-256 digests
#   - the entrypoint refuses to start without LAYA_API_KEY, sizes CPU threads from the
#     cgroup quota, then runs laya-serve as the unprivileged user "laya"
#
# Base image pinned by tag and digest (Docker Hub library/python, checked 2026-11-07).
# Upstream's own Dockerfile uses python:3.11-slim-trixie.
FROM python:3.11.18-slim-trixie@sha256:65bd3d9f1d7fa268dd1909973ba7eb4bdf41f6dcf2cfbe76ba9528b170f3fd79

# Bump together with requirements*.txt and reviewed-digests.json (TEMPLATE.md, "Upgrading").
# The self-test below fails the build if laya's reviewed revision no longer matches.
ARG PIN_LAYA=0.4.28
ARG PIN_REVIEWED_REVISION=55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    LAYA_DEVICE=cpu \
    USE_TF=0 \
    USE_TORCH=1 \
    TOKENIZERS_PARALLELISM=false \
    TORCH_DISABLE_NATIVE_JIT=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    HF_HUB_DISABLE_PROGRESS_BARS=1 \
    TEMPLATE_LAYA_VERSION=${PIN_LAYA} \
    TEMPLATE_DIGESTS_REVISION=${PIN_REVIEWED_REVISION}

# torch from the PyTorch CPU index only, then everything else from PyPI only. Hash-checked,
# wheels only, no dependency resolution at build time: the lock files are the whole set.
COPY requirements-torch.txt requirements.txt /opt/laya-railway/
RUN python -m venv /opt/venv \
 && pip install --retries 10 --timeout 60 --require-hashes --no-deps --only-binary=:all: \
      --index-url https://download.pytorch.org/whl/cpu -r /opt/laya-railway/requirements-torch.txt \
 && pip install --retries 10 --timeout 60 --require-hashes --no-deps --only-binary=:all: \
      --index-url https://pypi.org/simple -r /opt/laya-railway/requirements.txt \
 && pip check \
 && python -c "import torch; assert torch.version.cuda is None, torch.version.cuda; print('torch', torch.__version__, 'CPU')"

# Same unprivileged user as upstream's image (UID/GID 10001), so a cache copied from an
# upstream container keeps working.
RUN groupadd --gid 10001 laya \
 && useradd --uid 10001 --gid laya --create-home --home-dir /home/laya --shell /usr/sbin/nologin laya

COPY --chmod=0644 laya_railway.py reviewed-digests.json /opt/laya-railway/
COPY --chmod=0755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint
RUN bash -n /usr/local/bin/railway-entrypoint \
 && python /opt/laya-railway/laya_railway.py --self-test \
 && rm -rf /root/.cache

ENV PORT=8080
EXPOSE 8080
WORKDIR /home/laya

# Railway's init is PID 1 and reaps children; the entrypoint execs into laya-serve, so
# SIGTERM on redeploy reaches uvicorn directly and in-flight requests finish.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint"]
