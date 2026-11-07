# Deploy and Host Laya with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/laya-v04-decision-engine-api-jev-compati?referralCode=20H68q)

Laya answers typed questions about a piece of text (which option fits, where it sits on a scale, yes or no) with calibrated probabilities from a single forward pass instead of generated text. Code and weights are Apache-2.0. This template runs Laya 0.4.28's own HTTP server on CPU behind a generated API key.

## About Hosting Laya

Laya ships `laya-serve`, an HTTP server that speaks the request and answer format of TypeSafe's Jev decision API, so a Jev client can point its base URL at your deployment. Self-hosting it means a Python and PyTorch stack, model weights to download and keep, CPU thread tuning and an API key, since the server is open by default. This community template builds Laya 0.4.28 with every Python package pinned by SHA-256 and CPU-only PyTorch, refuses to start without a key, keeps the checkpoints on a volume, pins them to the revision Laya itself reviewed and verifies their SHA-256 digests before loading.

## Common Use Cases

- Triage inbound tickets, emails and chats into queues, and hand low-confidence ones to a person
- Policy, safety or relevance checks around an LLM call that cost CPU time instead of tokens
- Rate urgency, sentiment or lead quality on a fixed scale, in English and 100+ other languages
- A self-hosted endpoint for code already written against the Jev `/v1/systemone` API

## Dependencies for Laya Hosting

- A Railway volume at `/data` for the model cache (included, about 1.5 GB with the default checkpoints)
- Outbound access to Hugging Face on first boot to download the checkpoints
- About 5 GB of RAM for the default two checkpoints (measured on Railway after the first requests), so a Hobby or Pro plan (Trial's 1 GB is too small)

### Deployment Dependencies

- Laya source and docs: https://github.com/NandhaKishorM/laya
- HTTP API reference: https://github.com/NandhaKishorM/laya/blob/v0.4.28/docs/http-api.md
- Checkpoints on Hugging Face: https://huggingface.co/convaiinnovations/laya
- Checkpoint integrity (revision pins, digests): https://github.com/NandhaKishorM/laya/blob/v0.4.28/docs/security.md
- Railway volumes: https://docs.railway.com/volumes

### Implementation Details

| Service | Source | Purpose |
|---|---|---|
| Laya | Dockerfile: `python:3.11.18-slim-trixie` (digest-pinned), laya 0.4.28, torch 2.14.0 CPU | `laya-serve` on `PORT` 8080, public HTTPS domain, healthcheck `/health`, volume `/data` |

**First boot.** The service downloads the `english` (ModernBERT-large, 421M parameters) and `multilingual` (mmBERT-base, 322M, 100+ languages) checkpoints, about 1.5 GB, verifies them and loads them before it reports healthy. Allow a few minutes. Later restarts load from the volume in seconds.

**Call it.** Copy `LAYA_API_KEY` from the service's Variables tab and send it as a Bearer token. Only `GET /health` answers without it, with `{"status": "ok"}`; with the key it also lists the loaded checkpoints and their revisions. laya-serve switches off its interactive `/docs` page whenever a key is set; the HTTP API reference linked above covers every field.

```bash
curl https://{your-domain}/v1/systemone \
  -H "Authorization: Bearer {LAYA_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"state": "I was charged twice for my subscription. Please refund the duplicate.",
       "questions": {
         "department": {"type": "choice", "instructions": "Which department should handle this?",
                        "criteria": {"billing": "payments, refunds", "technical": "bugs, outages"}},
         "urgency": {"type": "score", "instructions": "How urgent is it?",
                     "criteria": ["not urgent", "soon", "blocking"]},
         "refund": {"type": "noul", "instructions": "Does the customer ask for a refund?"}}}'
```

Each answer carries its `choice`, `score` or `noul` (probability of yes) value and a `confidence`; choice and score answers also list `probabilities`. `routing` says which checkpoint answered and why. `POST /v1/systemone/batch` takes up to 64 `states` per call and `POST /v1/route` shows the routing decision without inference.

**Jev clients.** Set the client's base URL to `https://{your-domain}` and its API key to `LAYA_API_KEY` (sent as `Authorization: Bearer`). Jev model names such as `jev-1` mean "let the router choose". Set `LAYA_JEV_STRICT=1` for clients that reject fields Jev does not send. Before moving production traffic from Jev, evaluate Laya on a labelled sample of your own requests; upstream's `BENCHMARKS.md` lists where each one leads.

**From another Railway service** stay on the private network: base URL `http://${{Laya.RAILWAY_PRIVATE_DOMAIN}}:${{Laya.PORT}}`, key `${{Laya.LAYA_API_KEY}}`. The server listens on IPv4 and IPv6.

**Models.** Each request is routed by language: English text to `english`, other languages and undetectable text to `multilingual`. Send `"model": "multilingual"` (or `english`, `typed-decisions`) in a request to force one.

- `LAYA_MODELS` sets what loads at startup. Routing still loads the other checkpoint the first time a request needs it, and `LAYA_MAX_LOADED` (default 2) keeps both resident.
- Lean, about 2 GB of RAM: `LAYA_MODELS=multilingual` and `"model": "multilingual"` in every request. About three times faster per question on CPU, at some English accuracy (upstream's 51-language sweep: 0.71 against 0.82 on English). `LAYA_MAX_LOADED=1` makes it a hard cap; a request routed elsewhere then swaps checkpoints, taking seconds.
- `LAYA_DEFAULT_MODEL=english` when most of your undetectable text is English.
- `typed-decisions` is fine-tuned for four specific workflows and loads only when a request names it (or with `LAYA_AUTO_TASK=1`).
- Your own fine-tune: `LAYA_EXTRA_MODELS={"mine": "org/repo"}`, then clear `LAYA_REVISION` (the reviewed pin only covers Laya's own repository).

**Long texts.** The encoders read 512 (english) or 1,024 (multilingual) tokens by default and truncate the rest; a request may raise `max_len` up to 8,192. Laya 0.4.28 can send texts past 8,192 tokens to its 0.8B "vega" reader instead. On CPU that adds 2 to 4 GB of RAM and slow answers, so this template keeps it off; `TEMPLATE_VEGA_LANE=auto` turns it on.

**Performance.** Upstream's CPU benchmark (4 EPYC cores, fp32) measured about 0.6 s per question on `english` and 0.2 s on `multilingual`, growing linearly with the number of questions. Requests run one forward pass at a time; up to 16 wait in line (`LAYA_MAX_CONCURRENT`), more get a 503 with `Retry-After`. Threads follow the service's CPU quota (at most 8, `LAYA_THREADS` overrides).

**Scaling.** Scale vertically: give the service more CPU for faster answers and more RAM for more resident checkpoints. Keep one replica with the volume; for more throughput, deploy a second Laya service.

**Supply chain.** Python packages are installed from hash-pinned lock files, torch from the PyTorch CPU index only. `LAYA_REVISION=reviewed` pins the checkpoints to the Hugging Face commit Laya 0.4.28 reviewed, and the SHA-256 of every file Laya parses (except the tokenizer config Laya rewrites) is checked before loading. A mismatch stops the start.

**Upgrading.** The laya version, lock files and digests live in `services/laya` of the template repository; bump them together and redeploy. A redeploy with a volume has a short downtime while the checkpoints reload.

This is a community template. It is not affiliated with or endorsed by the Laya authors, Convai Innovations, TypeSafe or Railway. Check each checkpoint's model card for its licence and limits before production use.

### Why Deploy Laya on Railway?

Railway gives Laya an HTTPS domain, a volume for the weights and private networking to the rest of your stack, with nothing to administer. You pay for the CPU and memory the service uses, and your text stays on infrastructure you control.
