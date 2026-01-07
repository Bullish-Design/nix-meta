#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# scripts/setup-sops.py

"""
Initial setup script for sops-nix configuration.
Run this on your development machine before deploying to a new system.
"""

import subprocess
import sys
from pathlib import Path


def run_command(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command."""
    print(f"Running: {' '.join(cmd)}")
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def get_age_key_from_ssh(ssh_key_path: str) -> str:
    """Convert SSH public key to age format."""
    result = run_command(["ssh-to-age", "-i", ssh_key_path])
    return result.stdout.strip()


def create_sops_yaml(age_key: str, config_dir: Path) -> None:
    """Create .sops.yaml configuration."""
    sops_yaml = config_dir / ".sops.yaml"
    content = f"""# .sops.yaml
keys:
  - &host_key {age_key}

creation_rules:
  - path_regex: secrets/secrets\\.yaml$
    key_groups:
      - age:
          - *host_key
"""
    sops_yaml.write_text(content)
    print(f"Created {sops_yaml}")


def create_secrets_file(github_key_path: str, config_dir: Path) -> None:
    """Create and encrypt secrets.yaml with GitHub SSH key."""
    secrets_dir = config_dir / "secrets"
    secrets_dir.mkdir(exist_ok=True)

    secrets_yaml = secrets_dir / "secrets.yaml"
    github_key = Path(github_key_path).expanduser().read_text()

    # Create unencrypted template
    unencrypted_content = f"""# secrets.yaml
github_ssh_key: |
{chr(10).join('  ' + line for line in github_key.splitlines())}
"""

    temp_file = secrets_dir / "secrets.yaml.tmp"
    temp_file.write_text(unencrypted_content)

    # Encrypt with sops
    print(f"Encrypting {secrets_yaml}...")
    run_command([
        "sops",
        "--encrypt",
        "--in-place",
        str(temp_file),
    ])

    # Move to final location
    temp_file.rename(secrets_yaml)
    print(f"Created encrypted {secrets_yaml}")


def main() -> None:
    """Main setup workflow."""
    print("sops-nix Setup Script")
    print("=" * 50)

    # Get paths
    config_dir = Path.cwd()
    if not (config_dir / "flake.nix").exists():
        print("Error: Run this from your nix-meta directory")
        sys.exit(1)

    # Get SSH host key
    print("\nStep 1: Get your SSH host key")
    print("On your target system, run:")
    print("  cat /etc/ssh/ssh_host_ed25519_key.pub")
    ssh_pub_key = input("\nPaste the public key here: ").strip()

    if not ssh_pub_key:
        print("Error: No SSH key provided")
        sys.exit(1)

    # Convert to age
    print("\nConverting SSH key to age format...")
    # Save temporarily
    temp_ssh = Path("/tmp/temp_ssh_key.pub")
    temp_ssh.write_text(ssh_pub_key)
    age_key = get_age_key_from_ssh(str(temp_ssh))
    temp_ssh.unlink()

    print(f"Age key: {age_key}")

    # Create .sops.yaml
    print("\nStep 2: Creating .sops.yaml...")
    create_sops_yaml(age_key, config_dir)

    # Get GitHub SSH key
    print("\nStep 3: Encrypt GitHub SSH key")
    default_key = "~/.ssh/id_ed25519"
    github_key_path = input(f"Path to your GitHub SSH private key [{default_key}]: ").strip()
    if not github_key_path:
        github_key_path = default_key

    github_key_path = Path(github_key_path).expanduser()
    if not github_key_path.exists():
        print(f"Error: Key not found at {github_key_path}")
        sys.exit(1)

    create_secrets_file(str(github_key_path), config_dir)

    print("\n" + "=" * 50)
    print("Setup complete!")
    print("\nNext steps:")
    print("1. Commit .sops.yaml and secrets/secrets.yaml to git")
    print("2. Deploy your configuration: nixos-rebuild switch --flake .")
    print("3. Your GitHub SSH key will be available at ~/.ssh/github")


if __name__ == "__main__":
    main()
