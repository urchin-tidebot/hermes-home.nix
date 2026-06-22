{
  description = "Home Manager module for declarative Hermes Agent configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    in
    {
      homeManagerModules = {
        default = self.homeManagerModules.hermes-agent;
        hermes-agent = import ./modules/hermes-agent/home-manager.nix;
      };

      checks = eachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          basicConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/basic-home.nix
            ];
          };
          executableOnlyConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/executable-only-home.nix
            ];
          };
          nonGatewayConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/non-gateway-home.nix
            ];
          };
          basicExecStart = builtins.toJSON basicConfig.config.systemd.user.services.hermes-gateway.Service.ExecStart;
        in
        {
          config-merge = import ./tests/config-merge.nix { inherit pkgs; };
        }
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          basic = basicConfig.activationPackage;
          executable-only = executableOnlyConfig.activationPackage;
          gateway-execstart = pkgs.runCommand "hermes-gateway-execstart-check" { } ''
            case ${lib.escapeShellArg basicExecStart} in
              *"/bin/hermes gateway run --replace"*) touch "$out" ;;
              *)
                echo "unexpected ExecStart: ${lib.escapeShellArg basicExecStart}" >&2
                exit 1
                ;;
            esac
          '';
        }
        // lib.optionalAttrs (!pkgs.stdenv.isLinux) {
          non-gateway = nonGatewayConfig.activationPackage;
        }
      );

      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
