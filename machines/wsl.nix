{ inputs, ... }:

{
  imports = [
    inputs.nixos-core.nixosModules.wsl-upstream
    inputs.nixos-core.nixosModules.wsl
  ];

  # Enable WSL
  nixos-core.wsl.enable = true;

  # WSL-specific overrides
  home-manager.users.nixos = {
    programs.nix-terminal.zsh.aliases = {
      # Add WSL-specific aliases
      explorer = "explorer.exe";
      code = "code.exe";
    };
  };
}
