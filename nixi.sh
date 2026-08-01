#!/usr/bin/env bash
# nixi - imperative-ish package management for NixOS, edits configuration.nix + rebuilds

set -euo pipefail

CONFIG_FILE="/etc/nixos/configuration.nix"
BACKUP_DIR="/etc/nixos/.nixi-backups"
PKG_BLOCK_RE='^[[:space:]]*environment\.systemPackages[[:space:]]*=[[:space:]]*with[[:space:]]*pkgs;[[:space:]]*\['

usage() {
  cat <<'EOF'
usage:
  sudo nixi install <package>   add a package and rebuild
  sudo nixi remove <package>    remove a package and rebuild
  nixi list                     list packages currently in systemPackages
  nixi search <term>            search nixpkgs for a package name/description
EOF
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "needs root to edit $CONFIG_FILE and run nixos-rebuild, use sudo" >&2; exit 1; }
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || { echo "cant find $CONFIG_FILE" >&2; exit 1; }
  if ! grep -qE "$PKG_BLOCK_RE" "$CONFIG_FILE"; then
    echo "no 'environment.systemPackages = with pkgs; [ ... ];' block in $CONFIG_FILE, nixi only knows that exact form" >&2
    echo "add an empty one first and try again" >&2
    exit 1
  fi
}

# finds the "[" line and the closing "];" line
block_bounds() {
  local start end
  start=$(grep -nE "$PKG_BLOCK_RE" "$CONFIG_FILE" | head -n1 | cut -d: -f1)
  end=$(awk -v s="$start" 'NR>s && /^[[:space:]]*\];/{print NR; exit}' "$CONFIG_FILE")
  [[ -n "$end" ]] || { echo "couldnt find the closing '];' for the block" >&2; exit 1; }
  echo "$start $end"
}

pkg_installed() {
  local pkg="$1" start end
  read -r start end <<<"$(block_bounds)"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" | grep -qE "^[[:space:]]*${pkg}[[:space:]]*(#.*)?$"
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  local stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP_DIR/configuration.nix.$stamp"
  echo "$BACKUP_DIR/configuration.nix.$stamp"
}

rebuild_or_rollback() {
  local backup="$1"
  echo "rebuilding (nixos-rebuild switch)..."
  if nixos-rebuild switch; then
    echo done
    return
  fi
  echo "rebuild failed, restoring config from backup" >&2
  cp "$backup" "$CONFIG_FILE"
  echo "system is unaffected, old generation still active" >&2
  exit 1
}

cmd_install() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || usage
  require_root
  require_config

  if pkg_installed "$pkg"; then
    echo "'$pkg' is already in systemPackages"
    exit 0
  fi

  local backup start end
  backup=$(backup_config)
  read -r start end <<<"$(block_bounds)"
  sed -i "${start}a\\    ${pkg}" "$CONFIG_FILE"
  echo "added '$pkg' to $CONFIG_FILE"
  rebuild_or_rollback "$backup"
}

cmd_remove() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || usage
  require_root
  require_config

  if ! pkg_installed "$pkg"; then
    echo "'$pkg' isnt in systemPackages, nothing to do"
    exit 0
  fi

  local backup=$(backup_config)
  sed -i -E '/^[[:space:]]*'"${pkg}"'[[:space:]]*(#.*)?$/d' "$CONFIG_FILE"
  echo "removed '$pkg' from $CONFIG_FILE"
  rebuild_or_rollback "$backup"
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
  echo "searching nixpkgs for '$term', first run is slow..."
  nix-env -qaP --description 2>/dev/null | grep -i -- "$term" || echo "no matches"
}

case "${1:-}" in
  install) shift; cmd_install "${1:-}" ;;
  remove)  shift; cmd_remove "${1:-}" ;;
  list)    cmd_list ;;
  search)  shift; cmd_search "${1:-}" ;;
  *)       usage ;;
esac
