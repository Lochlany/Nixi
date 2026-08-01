#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/nixos/configuration.nix"
FLAKE_FILE="/etc/nixos/flake.nix"
BACKUP_DIR="/etc/nixos/.nixi-backups"
PKG_BLOCK_RE='^[[:space:]]*environment\.systemPackages[[:space:]]*=[[:space:]]*with[[:space:]]*pkgs;[[:space:]]*\['

usage() {
  cat <<'EOF'
nixi - imperative-ish package management for NixOS

  sudo nixi install <pkg>
  sudo nixi remove <pkg>
  sudo nixi upgrade
  nixi list
  nixi search <term>
EOF
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "needs sudo (edits $CONFIG_FILE, runs nixos-rebuild)" >&2; exit 1; }
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || { echo "no $CONFIG_FILE?" >&2; exit 1; }
  grep -qE "$PKG_BLOCK_RE" "$CONFIG_FILE" || {
    cat >&2 <<EOF
can't find "environment.systemPackages = with pkgs; [ ... ];" in $CONFIG_FILE
add an empty one first:

  environment.systemPackages = with pkgs; [
  ];
EOF
    exit 1
  }
}

# pkgs.foo and foo should count as the same package
bare() { echo "${1#pkgs.}"; }

block_bounds() {
  local start end
  start=$(grep -nE "$PKG_BLOCK_RE" "$CONFIG_FILE" | head -n1 | cut -d: -f1)
  end=$(awk -v s="$start" 'NR>s && /^[[:space:]]*\];/{print NR; exit}' "$CONFIG_FILE")
  [[ -n "$end" ]] || { echo "couldn't find the closing '];'" >&2; exit 1; }
  echo "$start $end"
}

pkg_installed() {
  local pkg start end
  pkg=$(bare "$1")
  read -r start end <<<"$(block_bounds)"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" \
    | sed -E 's/^[[:space:]]*pkgs\.//' \
    | grep -qE "^[[:space:]]*${pkg}[[:space:]]*(#.*)?$"
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  local dst="$BACKUP_DIR/configuration.nix.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_FILE" "$dst"
  echo "$dst"
}

do_rebuild() {
  if [[ -f "$FLAKE_FILE" ]]; then
    nixos-rebuild switch --flake "/etc/nixos#$(hostname)"
  else
    nixos-rebuild switch
  fi
}

rebuild_or_rollback() {
  local backup="$1"
  echo "rebuilding..."
  if do_rebuild; then
    echo "done."
  else
    echo "rebuild failed, restoring old config.nix" >&2
    cp "$backup" "$CONFIG_FILE"
    echo "system's fine, still on the old generation" >&2
    exit 1
  fi
}

cmd_install() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || usage
  require_root
  require_config

  if pkg_installed "$pkg"; then
    echo "'$pkg' already in there"
    exit 0
  fi

  local name backup start end
  name=$(bare "$pkg")
  backup=$(backup_config)
  read -r start end <<<"$(block_bounds)"
  sed -i "${start}a\\    ${name}" "$CONFIG_FILE"
  echo "added $name"
  rebuild_or_rollback "$backup"
}

cmd_remove() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || usage
  require_root
  require_config

  if ! pkg_installed "$pkg"; then
    echo "'$pkg' isn't in there"
    exit 0
  fi

  local backup name
  backup=$(backup_config)
  name=$(bare "$pkg")
  sed -i -E '/^[[:space:]]*(pkgs\.)?'"${name}"'[[:space:]]*(#.*)?$/d' "$CONFIG_FILE"
  echo "removed $name"
  rebuild_or_rollback "$backup"
}

cmd_upgrade() {
  require_root
  if [[ -f "$FLAKE_FILE" ]]; then
    echo "updating flake inputs..."
    nix flake update --flake /etc/nixos
  else
    echo "updating channels..."
    nix-channel --update
  fi
  echo "rebuilding..."
  do_rebuild
}

cmd_list() {
  require_config
  local start end
  read -r start end <<<"$(block_bounds)"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" | sed -E '/^[[:space:]]*(#.*)?$/d'
}

cmd_search() {
  local term="${1:-}"
  [[ -n "$term" ]] || usage
  echo "searching nixpkgs for '$term'..."
  if command -v fzf >/dev/null 2>&1; then
    local pick
    pick=$(nix-env -qaP --description 2>/dev/null \
      | grep -i -- "$term" \
      | fzf --prompt="install> " \
      | awk '{print $1}' | sed -E 's#^nixos\.##; s#^nixpkgs\.##')
    [[ -n "$pick" ]] && cmd_install "$pick"
  else
    nix-env -qaP --description 2>/dev/null | grep -i -- "$term" || echo "no matches"
  fi
}

case "${1:-}" in
  install) shift; cmd_install "${1:-}" ;;
  remove)  shift; cmd_remove "${1:-}" ;;
  upgrade) cmd_upgrade ;;
  list)    cmd_list ;;
  search)  shift; cmd_search "${1:-}" ;;
  *)       usage ;;
esac
