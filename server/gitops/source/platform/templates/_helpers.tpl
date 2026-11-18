{{- /*
The LiteLLM config, factored into a named template so that the Deployment can
hash it and restart when it changes.

Every model points at a host service through the cluster DNS names defined in
host-models.yaml. "strata" is whichever pack is currently launched - Strata
serves one at a time, so these are role aliases rather than distinct models.
See reference/agent-orchestration.md.
*/}}
{{- define "platform.litellmConfig" -}}
model_list:
  # The resident Strata pack. Used by brain and worker roles with different
  # reasoning_effort rather than different models.
  - model_name: brain
    litellm_params:
      model: openai/strata
      api_base: http://strata.{{ .Values.namespace }}.svc.cluster.local:8080/v1
      api_key: "local"
      # Highest reasoning tier. Strata's own default, stated explicitly so the
      # intent is visible in the config rather than implied.
      reasoning_effort: xhigh
      timeout: 900

  - model_name: worker
    litellm_params:
      model: openai/strata
      api_base: http://strata.{{ .Values.namespace }}.svc.cluster.local:8080/v1
      api_key: "local"
      # Short reasoning: workers execute a decided plan, they do not plan.
      reasoning_effort: low
      timeout: 300

  # The small GGUF held in VRAM by llama.cpp. Independent of Strata, which is
  # the whole point - a checker that shares a model with the worker shares its
  # blind spots too.
  - model_name: checker
    litellm_params:
      model: openai/local
      api_base: http://llamacpp.{{ .Values.namespace }}.svc.cluster.local:8081/v1
      api_key: "local"
      timeout: 180

  # Plain passthrough, for chat and anything that wants the raw model.
  - model_name: strata
    litellm_params:
      model: openai/strata
      api_base: http://strata.{{ .Values.namespace }}.svc.cluster.local:8080/v1
      api_key: "local"
      timeout: 900

  - model_name: local
    litellm_params:
      model: openai/local
      api_base: http://llamacpp.{{ .Values.namespace }}.svc.cluster.local:8081/v1
      api_key: "local"
      timeout: 300

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  # A concurrency cap, not a queue. Beyond this LiteLLM returns 429 - it
  # does not hold the request. Holding is what gpu-queue on 4100 does, and
  # it does that knowing what the GPU is actually doing. This is the hard
  # backstop underneath it, and it still applies to anything that bypasses
  # the queue and calls the gateway directly.
  #
  # 4 is deliberately low: Strata's hybrid mode holds ~1.5 GB of KV cache
  # per parallel slot at 32K context, and a 16 GB card supports about two
  # slots at that length.
  max_parallel_requests: {{ .Values.litellm.maxParallelRequests }}

litellm_settings:
  drop_params: true
  # Keep request logs bounded; see the retention table in
  # reference/server-architecture.md.
  maximum_spend_logs_retention_period: {{ .Values.litellm.spendLogsRetention | quote }}
  request_timeout: {{ .Values.litellm.requestTimeout }}
  # Do not retry a timed-out generation. On this hardware a timeout means the
  # model is loading or the queue is deep, and a retry makes both worse.
  num_retries: 0
{{- end -}}
