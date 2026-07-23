import talos_core/config

let cfg = loadConfig()
echo "Provider: ", cfg.provider
echo "VLLM Endpoint: ", cfg.vllmEndpoint
echo "Max Tokens: ", cfg.maxTokens
echo "Temperature: ", cfg.temperature
