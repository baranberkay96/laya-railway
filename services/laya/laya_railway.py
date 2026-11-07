"""Start laya-serve for the Railway template, with two CPU settings laya-serve has no variable for.

1. The vega lane (laya 0.4.25 and newer). With the vegaml package installed, which laya 0.4.28
   installs as a core dependency, laya's Router sends a state longer than about 8,192 tokens, and
   any request with "model": "vega", to vegaml's 0.8B decoder reader. That reader is downloaded
   and built on first use; upstream quotes two to four gigabytes of memory for it and about five
   times the encoder latency. On a CPU service that is a surprise in memory, volume space and
   response time, so this template keeps the lane off unless TEMPLATE_VEGA_LANE=auto.
   `Router(vega=False)` is upstream's documented switch (docs/routing.md, "The vega lane").
   laya.serve.build_router builds its Router with `from .router import Router` at call time, so a
   subclass that defaults `vega` to False, installed on laya.router before the server starts, is
   the class it constructs. `--self-test` (run by the Dockerfile) proves that for the pinned laya.

2. Inter-op threads. laya-serve caps torch's intra-op pool (LAYA_THREADS); upstream's CPU
   benchmark (BENCHMARKS.md, laptop CPU section) also pins the inter-op pool to one thread, since
   one forward pass per call leaves it nothing to overlap. TEMPLATE_INTEROP_THREADS (default 1).

Everything else is laya-serve unchanged: this module ends in laya.serve.main().
"""
import json
import os
import re
import sys

VEGA_MODES = ("off", "auto")
DIGESTS_FILE = "/opt/laya-railway/reviewed-digests.json"
BUILTIN_CHECKPOINTS = ("english", "multilingual", "typed-decisions")
BUNDLE_REPO = "convaiinnovations/laya"
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")


def log(message: str) -> None:
    print("[laya-railway] " + message, file=sys.stderr, flush=True)


def vega_mode() -> str:
    raw = (os.environ.get("TEMPLATE_VEGA_LANE") or "off").strip().lower()
    if raw not in VEGA_MODES:
        raise SystemExit("TEMPLATE_VEGA_LANE must be 'off' or 'auto', got %r" % raw)
    return raw


def interop_threads() -> int:
    raw = (os.environ.get("TEMPLATE_INTEROP_THREADS") or "1").strip()
    if not raw.isdigit() or int(raw) < 1:
        raise SystemExit("TEMPLATE_INTEROP_THREADS must be a positive integer, got %r" % raw)
    return int(raw)


def install_vega_switch(mode: str) -> None:
    """Make laya.router.Router default to vega=False unless the lane is wanted."""
    if mode == "auto":
        return
    import laya.router as router_module

    upstream = router_module.Router
    if getattr(upstream, "_railway_vega_default", None) is not None:
        return

    class Router(upstream):  # noqa: D101 -- same class, one default changed
        _railway_vega_default = False

        def __init__(self, *args: object, **kwargs: object) -> None:
            kwargs.setdefault("vega", False)
            super().__init__(*args, **kwargs)

    Router.__module__ = upstream.__module__
    Router.__qualname__ = upstream.__qualname__
    Router.__doc__ = upstream.__doc__
    router_module.Router = Router


def set_interop_threads(count: int) -> None:
    import torch

    try:
        torch.set_num_interop_threads(count)
    except RuntimeError as error:  # only raised once parallel work has started
        log("could not set inter-op threads to %d: %s" % (count, error))


def check(condition: bool, message: str) -> None:
    """An assert that survives `python -O`."""
    if not condition:
        raise SystemExit("laya-railway self-test failed: " + message)


def self_test() -> None:
    """Build-time checks against the installed laya. Builds Routers without loading weights."""
    from importlib.metadata import version

    from laya.revisions import PINNED_REVISIONS, resolve_revision

    expected_version = os.environ.get("TEMPLATE_LAYA_VERSION", "")
    installed = version("laya")
    check(installed == expected_version,
          "laya %s installed, the Dockerfile pins %s" % (installed, expected_version))

    revision = os.environ.get("TEMPLATE_DIGESTS_REVISION", "")
    pinned = PINNED_REVISIONS.get(BUNDLE_REPO)
    check(pinned == revision,
          "laya's reviewed revision for %s is %s, reviewed-digests.json was made for %s; "
          "regenerate the digests" % (BUNDLE_REPO, pinned, revision))
    os.environ["LAYA_REVISION"] = "reviewed"
    check(resolve_revision(BUNDLE_REPO) == revision, "LAYA_REVISION=reviewed does not resolve")

    with open(DIGESTS_FILE, encoding="utf-8") as handle:
        digests = json.load(handle)
    check(sorted(digests) == sorted(BUILTIN_CHECKPOINTS), "digest map names %s" % sorted(digests))
    for name, files in digests.items():
        check(bool(files) and all(SHA256_HEX.match(v) for v in files.values()),
              "malformed digests for %s" % name)

    os.environ["LAYA_PRELOAD"] = "0"
    os.environ["LAYA_DEVICE"] = "cpu"
    os.environ["LAYA_SHA256_DIGESTS"] = json.dumps(digests)
    from laya import serve

    stock = serve.build_router()
    check(stock.vega_enabled, "vegaml missing: the stock Router has no vega lane to turn off")
    install_vega_switch("off")
    router = serve.build_router()
    check(not router.vega_enabled, "build_router no longer honours the vega switch")
    check(router.default == "multilingual", "router default is %r" % router.default)
    for name in BUILTIN_CHECKPOINTS:
        check(router.sha256_digests.get(name) == digests[name],
              "LAYA_SHA256_DIGESTS did not reach the %s checkpoint" % name)
    log("self-test ok: laya %s, reviewed revision %s, digests parsed, vega lane switchable"
        % (installed, revision))


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    mode = vega_mode()
    interop = interop_threads()
    set_interop_threads(interop)
    install_vega_switch(mode)
    log("vega lane %s; torch inter-op threads %d" % (mode, interop))
    from laya.serve import main as serve_main

    serve_main()


if __name__ == "__main__":
    main()
