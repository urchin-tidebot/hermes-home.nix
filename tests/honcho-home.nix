{ ... }:

{
  services.honcho = {
    enable = true;
    environmentFiles = [ "/run/secrets/honcho.env" ];
    postgres.enable = true;
    redis.enable = true;
    settings = {
      llm.ANTHROPIC_BASE_URL = "https://api.minimax.io/anthropic";
      embedding.model_config.overrides.base_url = "https://openrouter.ai/api/v1";
    };
  };

  home.username = "honcho-test";
  home.homeDirectory = "/tmp/honcho-home-test";
  home.stateVersion = "26.05";
}
