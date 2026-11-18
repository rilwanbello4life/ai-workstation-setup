"""Settings, all overridable by environment variable from the Deployment.

Defaults are the in-cluster DNS names created by 03-host-models.yaml and
06-gpu-probe.yaml, so the service works with no configuration at all.
"""

import os


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, "") or default)
    except ValueError:
        return default


class Settings:
    # --- upstreams ---------------------------------------------------------
    # LiteLLM stays the authority on authorisation. The queue forwards the
    # caller's own key to it unchanged, so budgets, rate limits, model
    # allowlists and spend logging keep working exactly as before.
    litellm_base = os.getenv(
        "LITELLM_BASE", "http://litellm.platform.svc.cluster.local:4000"
    ).rstrip("/")
    gpu_probe_base = os.getenv(
        "GPU_PROBE_BASE", "http://gpu-probe.platform.svc.cluster.local:8101"
    ).rstrip("/")
    comfyui_base = os.getenv(
        "COMFYUI_BASE", "http://comfyui.platform.svc.cluster.local:8188"
    ).rstrip("/")

    database_url = os.getenv("DATABASE_URL", "")
    master_key = os.getenv("LITELLM_MASTER_KEY", "")

    output_dir = os.getenv("OUTPUT_DIR", "/srv/platform/gpu-queue/outputs")

    # --- admission ---------------------------------------------------------
    # Keep this much VRAM unclaimed. The desktop compositor holds 1-1.5 GB
    # and Strata grows its KV cache as a conversation lengthens, so admitting
    # work that exactly fills the card is how you get an allocation failure
    # several minutes into a generation rather than at the start.
    vram_reserve_mb = _int("VRAM_RESERVE_MB", 2048)

    # One heavy job at a time, always. Heavy means xhigh reasoning or a batch
    # render, either of which can hold the card for minutes.
    max_heavy = _int("MAX_HEAVY", 1)

    # Light jobs start here and rise toward max_light_ceiling while the card
    # looks underused. This is the "if the GPU is not busy, take another job"
    # behaviour: a quiet card earns more concurrency, a loaded one does not.
    light_floor = _int("LIGHT_FLOOR", 2)
    light_ceiling = _int("LIGHT_CEILING", 4)
    # Below this utilisation the card is considered to have spare capacity.
    idle_util_pct = _int("IDLE_UTIL_PCT", 50)
    # ...and it also needs this much free VRAM beyond the reserve before the
    # limit is allowed to rise.
    growth_headroom_mb = _int("GROWTH_HEADROOM_MB", 2048)

    # What counts as heavy.
    heavy_models = set(
        filter(None, os.getenv("HEAVY_MODELS", "brain").split(","))
    )
    heavy_reasoning = {"high", "xhigh"}
    heavy_max_tokens = _int("HEAVY_MAX_TOKENS", 4096)

    # --- behaviour ---------------------------------------------------------
    dispatch_interval = float(os.getenv("DISPATCH_INTERVAL", "0.2"))
    gpu_poll_interval = float(os.getenv("GPU_POLL_INTERVAL", "2.0"))
    # How long a caller will hold a connection waiting for a slot before the
    # queue gives up and tells them to retry.
    queue_timeout = _int("QUEUE_TIMEOUT", 600)
    upstream_timeout = _int("UPSTREAM_TIMEOUT", 1800)
    key_cache_seconds = _int("KEY_CACHE_SECONDS", 60)

    # When Postgres is unreachable the queue still proxies, using this
    # profile for everyone. Degrading to "no personalisation" is correct;
    # degrading to "nobody can use their models" is not.
    fallback_max_concurrent = _int("FALLBACK_MAX_CONCURRENT", 1)
    fallback_queue_depth = _int("FALLBACK_QUEUE_DEPTH", 10)


settings = Settings()
