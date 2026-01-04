# AGENTS.md

## Repository Overview

**nix-meta** is the top-level orchestration flake that composes machine configurations from profiles and upstream modules. It defines complete NixOS systems by combining:
- `nixos-core` - System-level NixOS modules
- `nix-terminal` - Home Manager terminal environment
- `home-manager` - User environment management

## Architecture

```
flake.nix
    │
    ├── profiles/           # Composable configuration sets
    │   ├── default.nix     # Profile exports
    │   ├── developer.nix   # Full dev environment
    │   ├── minimal.nix     # Bare essentials
    │   └── gui.nix         # Desktop additions
    │
    └── machines/           # Machine-specific overrides
        ├── wsl.nix         # WSL-specific
        ├── desktop.nix     # Desktop-specific
        └── server.nix      # Server-specific
```

### Configuration Flow

```
Machine config (hardware/overrides)
        ↓
    + Profiles (developer, gui, minimal)
        ↓
    = Complete NixOS configuration
```

## Making Changes

### Adding a New Machine

1. Create `machines/<n>.nix`:
```nix
{ inputs, ... }:
{
  imports = [
    # Hardware configuration
    # Machine-specific modules
  ];
  
  # Machine-specific overrides
}
```

2. Add to `flake.nix`:
```nix
nixosConfigurations.<n> = mkMachine "<n>" [ profiles.developer ];
```

### Creating a New Profile

1. Create `profiles/<n>.nix`:
```nix
inputs:
{ pkgs, ... }:
let
  inherit (inputs) nixos-core nix-terminal home-manager;
in
{
  imports = [ /* modules */ ];
  # Configuration
}
```

2. Export in `profiles/default.nix`:
```nix
{
  # existing profiles...
  <n> = import ./<n>.nix inputs;
}
```

### Modifying User Configuration

User config lives in profiles under `home-manager.users.<username>`:

```nix
home-manager.users.nixos = { ... }: {
  imports = [
    nix-terminal.homeManagerModules.terminal
  ];
  
  programs.nix-terminal = {
    enable = true;
    # options...
  };
};
```

## Constraints

- **Profiles are composable**: Design for `[ profiles.a profiles.b ]` usage
- **Machines are minimal**: Only hardware and overrides, not full config
- **Username is `nixos`**: Hardcoded in current profiles
- **Single system arch**: Currently `x86_64-linux` only

## Integration Points

### Upstream Dependencies

| Input | Usage |
|-------|-------|
| `nixos-core` | `nixosModules.common`, `nixosModules.wsl` |
| `nix-terminal` | `homeManagerModules.terminal`, `homeManagerModules.nixbuild` |
| `home-manager` | `nixosModules.home-manager` |

### Profile Inheritance

Profiles can be combined:
```nix
desktop = mkMachine "desktop" [ profiles.developer profiles.gui ];
```

Order matters - later profiles can override earlier ones.

## Common Tasks

### Add package to developer profile
Update `profiles/developer.nix`:
```nix
programs.nix-terminal.extraPackages = with pkgs; [
  # existing...
  newpackage
];
```

### Add shell alias for all machines
Update `profiles/developer.nix` under `zsh.aliases`:
```nix
aliases = {
  # existing...
  newalias = "command";
};
```

### Add machine-specific alias
Update `machines/<machine>.nix`:
```nix
home-manager.users.nixos.programs.nix-terminal.zsh.aliases = {
  specific = "command";
};
```

### Change default git branch
Update `profiles/developer.nix`:
```nix
programs.nix-terminal.gitDefaultBranch = "main";
```

## Testing

```bash
# Check flake
nix flake check

# Build specific machine
nix build .#nixosConfigurations.wsl.config.system.build.toplevel

# Dry-run rebuild
nixos-rebuild dry-build --flake .#wsl
```

## File Locations

| What | Where |
|------|-------|
| Machine definitions | `machines/*.nix` |
| Profile definitions | `profiles/*.nix` |
| Profile exports | `profiles/default.nix` |
| System builder helper | `flake.nix` (`mkMachine`) |
