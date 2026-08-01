#!/usr/bin/env bash
#
# nixi - imperative package management for NixOS
# Edits environment.systemPackages in /etc/nixos/configuration.nix
# and runs nixos-rebuild switch, like `sudo nixi install firefox`.
#
set -euo pipefail

CONFIG_FILE="/etc/nixos/configuration.nix"
BACKUP_DIR="/etc/nixos/.nixi-backups"
PKG_BLOCK_RE='^[[:space:]]*environment\.systemPackages[[:space:]]*=[[:space:]]*with[[:space:]]*pkgs;[[:space:]]*\['

usage() {
  cat <<'EOF'
nixi - manage NixOS packages imperatively (edits configuration.nix + rebuilds)

usage:
  sudo nixi install <package>   add a package and rebuild
  sudo nixi remove <package>    remove a package and rebuild
  nixi list                     list packages currently in systemPackages
  nixi search <term>            search nixpkgs for a package name/description
EOF
  exit 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "this needs to edit $CONFIG_FILE and run nixos-rebuild — run with sudo." >&2
    exit 1
  fi
}

require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "cant find $CONFIG_FILE" >&2
    exit 1
  fi
  if ! grep -qE "$PKG_BLOCK_RE" "$CONFIG_FILE"; then
    cat >&2 <<EOF
couldnt find an 'environment.systemPackages = with pkgs; [ ... ];' block
in $CONFIG_FILE. nixi only knows how to edit that exact form.

Add an empty one manually first, e.g.:

  environment.systemPackages = with pkgs; [
  ];

then try again.
EOF
    exit 1
  fi
}

block_bounds() {
  # prints "start end" line numbers: the "[" line and the "];" line
  local start end
  start=$(grep -nE "$PKG_BLOCK_RE" "$CONFIG_FILE" | head -n1 | cut -d: -f1)
  end=$(awk -v s="$start" 'NR>s && /^[[:space:]]*\];/{print NR; exit}' "$CONFIG_FILE")
  if [[ -z "$end" ]]; then
    echo "couldnt find the closing '];' for the systemPackages block." >&2
    exit 1
  fi
  echo "$start $end"
}

pkg_installed() {
  local pkg="$1" start end
  read -r start end <<<"$(block_bounds)"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" | grep -qE "^[[:space:]]*${pkg}[[:space:]]*(#.*)?$"
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP_DIR/configuration.nix.$stamp"
  echo "$BACKUP_DIR/configuration.nix.$stamp"
}

rebuild_or_rollback() {
  local backup="$1"
  echo "rebuilding NixOS (nixos-rebuild switch)..."
  if nixos-rebuild switch; then
    echo "Done."
  else
    echo "rebuild failed — restoring $CONFIG_FILE from backup." >&2
    cp "$backup" "$CONFIG_FILE"
    echo "your running system is unaffected (old generation is still active)." >&2
    exit 1
  fi
}

cmd_install() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || usage
  require_root
  require_config

  if pkg_installed "$pkg"; then
    echo "'$pkg' is already in systemPackages."
    exit 0
  fi

  local backup start end
  backup=$(backup_config)
  read -r start end <<<"$(block_bounds)"
  sed -i "${start}a\\    ${pkg}" "$CONFIG_FILE"
  echo "Added '$pkg' to $CONFIG_FILE."
  rebuild_or_rollback "$backup"
}

cmd_remove() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || usage
  require_root
  require_config

  if ! pkg_installed "$pkg"; then
    echo "'$pkg' isnt in systemPackages — so nothing to do."
    exit 0
  fi

  local backup
  backup=$(backup_config)
  sed -i -E '/^[[:space:]]*'"${pkg}"'[[:space:]]*(#.*)?$/d' "$CONFIG_FILE"
  echo "Removed '$pkg' from $CONFIG_FILE."
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
  echo "Searching nixpkgs for '$term' (this can take a moment the frist time)..."
  nix-env -qaP --description 2>/dev/null | grep -i -- "$term" || echo "No matches."
}

case "${1:-}" in
  install) shift; cmd_install "${1:-}" ;;
  remove)  shift; cmd_remove "${1:-}" ;;
  list)    cmd_list ;;
  search)  shift; cmd_search "${1:-}" ;;
  *)       usage ;;
esac
