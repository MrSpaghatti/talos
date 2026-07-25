## CLI-specific config overrides.
##
## Provides `RunOverrides` for per-run flag overrides (`--model`,
## `--provider`, `--temperature`) that layer on top of the base
## `talos_core/config.loadConfig()` without touching disk.

import talos_core/config

type
  RunOverrides* = object
    ## Per-run flag overrides. Empty/sentinel values mean "leave alone".
    model*: string
    provider*: string
    temperature*: float
    hasTemperature*: bool
    configPath*: string
    envPath*: string

proc emptyOverrides*(): RunOverrides =
  RunOverrides(
    model: "",
    provider: "",
    temperature: 0.0,
    hasTemperature: false,
    configPath: "",
    envPath: ".env",
  )

proc applyOverrides*(cfg: var TalosConfig; ov: RunOverrides) =
  ## Mutates `cfg` to reflect any non-empty fields of `ov`. The model
  ## override is applied to whichever provider is currently active so a
  ## simple `--model x` works regardless of provider.
  if ov.provider.len > 0:
    cfg.provider = ov.provider
  if ov.model.len > 0:
    case cfg.provider
    of "vllm":       cfg.vllmModel = ov.model
    of "openrouter": cfg.openrouterModel = ov.model
    else:            cfg.openrouterModel = ov.model
  if ov.hasTemperature:
    cfg.temperature = ov.temperature

proc loadConfigWithOverrides*(ov: RunOverrides): TalosConfig =
  ## Loads config from disk and applies per-run flag overrides. Validation
  ## is re-run after overrides so an invalid provider on the CLI surfaces
  ## as a `ConfigError`.
  result = loadConfig(configPath = ov.configPath, envFilePath = ov.envPath)
  applyOverrides(result, ov)
  validate(result)
