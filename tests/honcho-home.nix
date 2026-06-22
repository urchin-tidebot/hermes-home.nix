{ ... }:

{
  services.honcho = {
    enable = true;
    environmentFiles = [ "/run/secrets/honcho.env" ];
    postgres.enable = true;
    redis.enable = true;
    llm.baseUrl = "https://api.minimax.io/anthropic";
    embeddings.baseUrl = "https://openrouter.ai/api/v1";
  };

  home.username = "honcho-test";
  home.homeDirectory = "/tmp/honcho-home-test";
  home.stateVersion = "26.05";
}
