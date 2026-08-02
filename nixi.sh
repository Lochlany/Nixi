#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/nixos/configuration.nix"
[[ -f /etc/nixos/.nixi.conf ]] && source /etc/nixos/.nixi.conf
FLAKE_FILE="/etc/nixos/flake.nix"
NIX_CONF="/etc/nix/nix.conf"
BACKUP_DIR="/etc/nixos/.nixi-backups"
CACHE_DIR="/etc/nixos/.nixi-cache"
OPTIONS_CACHE="$CACHE_DIR/options.txt"
PKG_BLOCK_RE='^[[:space:]]*environment\.systemPackages[[:space:]]*=[[:space:]]*with[[:space:]]*pkgs;[[:space:]]*\['

# anyone reading the code, this is just preset ones. You can run nixi refresh-options that gets all 2445.
declare -A KNOWN_OPTIONS=(
  [steam]="programs.steam.enable"
  [docker]="virtualisation.docker.enable"
  [git]="programs.git.enable"
  [zsh]="programs.zsh.enable"
  [fish]="programs.fish.enable"
  [tmux]="programs.tmux.enable"
  [wireshark]="programs.wireshark.enable"
  [adb]="programs.adb.enable"
  [gamemode]="programs.gamemode.enable"
  [light]="programs.light.enable"
  [firejail]="programs.firejail.enable"
  [dconf]="programs.dconf.enable"
  [seahorse]="programs.seahorse.enable"
  [java]="programs.java.enable"
  [mosh]="programs.mosh.enable"
)

usage() {
  cat <<'EOF'
nixi - imperative-ish package management for NixOS

  sudo nixi install <pkg>
  sudo nixi remove <pkg>
  sudo nixi upgrade
  sudo nixi refresh-options   rebuild the option-detection cache (slow, run it occasionally)
  sudo nixi fmt               tidy systemPackages: one per line, sorted, deduped
  sudo nixi rollback          go back one generation
  sudo nixi rollback list     show available generations
  sudo nixi rollback <N>      switch to generation N
  nixi list
  nixi search <term>

point nixi at a different file (split configs, flake modules) by putting
  CONFIG_FILE=/path/to/your/file.nix
in /etc/nixos/.nixi.conf
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

bare() { echo "${1#pkgs.}"; }

using_flakes() {
  [[ -f "$FLAKE_FILE" ]] && grep -qE '(^|[[:space:]])experimental-features[[:space:]]*=.*flakes' "$NIX_CONF" 2>/dev/null
}

block_bounds() {
  local start end
  start=$(grep -nE "$PKG_BLOCK_RE" "$CONFIG_FILE" | head -n1 | cut -d: -f1)
  end=$(awk -v s="$start" 'NR>s && /^[[:space:]]*\];/{print NR; exit}' "$CONFIG_FILE")
  if [[ -z "$end" ]]; then
    if sed -n "${start}p" "$CONFIG_FILE" | grep -qE '\];'; then
      cat >&2 <<EOF
your systemPackages block is all on one line - nixi needs the closing '];'
on its own line. split it into:

  environment.systemPackages = with pkgs; [
    ...
  ];
EOF
    else
      echo "couldn't find the closing '];'" >&2
    fi
    exit 1
  fi
  echo "$start $end"
}

pkg_installed() {
  local pkg start end
  pkg=$(bare "$1")
  read -r start end <<<"$(block_bounds)"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" \
    | sed -E 's/#.*//' \
    | tr -s '[:space:]' '\n' \
    | sed -E 's/^pkgs\.//' \
    | grep -qxF "$pkg"
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  local dst="$BACKUP_DIR/configuration.nix.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_FILE" "$dst"
  echo "$dst"
}

option_set() {
  local esc="${1//./\\.}"
  grep -qE "^[[:space:]]*${esc}[[:space:]]*=" "$CONFIG_FILE"
}

add_option() {
  local opt="$1" backup lastbrace
  backup=$(backup_config)
  lastbrace=$(grep -n '^}' "$CONFIG_FILE" | tail -n1 | cut -d: -f1)
  [[ -n "$lastbrace" ]] || { echo "couldn't find the file's closing '}'" >&2; exit 1; }
  sed -i "${lastbrace}i\\  ${opt} = true;" "$CONFIG_FILE"
  echo "added ${opt} = true;"
  rebuild_or_rollback "$backup"
}

remove_option() {
  local opt="$1" backup esc
  backup=$(backup_config)
  esc="${opt//./\\.}"
  sed -i -E "\\#^[[:space:]]*${esc}[[:space:]]*=#d" "$CONFIG_FILE"
  echo "removed ${opt} = true;"
  rebuild_or_rollback "$backup"
}

cmd_refresh_options() {
  require_root
  mkdir -p "$CACHE_DIR"
  local walker out
  walker=$(mktemp --suffix=.nix)
  echo "evaluating the nixos option tree, this can take a minute..."

  if using_flakes; then
    cat > "$walker" <<'NIXEOF'
let
  flake = builtins.getFlake (toString /etc/nixos);
  cfg = flake.nixosConfigurations.__HOSTNAME__;
  lib = cfg.pkgs.lib;
  isOpt = v: builtins.isAttrs v && (v._type or "") == "option";
  walk = prefix: node:
    if isOpt node then
      (if lib.hasSuffix ".enable" prefix then [ prefix ] else [])
    else if builtins.isAttrs node then
      let r = builtins.tryEval (lib.mapAttrsToList
        (n: v: walk (if prefix == "" then n else "${prefix}.${n}") v) node);
      in if r.success then lib.concatLists r.value else []
    else [];
in walk "" cfg.options
NIXEOF
    sed -i "s/__HOSTNAME__/$(hostname)/" "$walker"
    out=$(nix eval --json --extra-experimental-features "nix-command flakes" --file "$walker" 2>/tmp/nixi-eval.log) \
      || { echo "eval failed, see /tmp/nixi-eval.log - keeping the old cache if there is one" >&2; rm -f "$walker"; return 1; }
  else
    cat > "$walker" <<'NIXEOF'
let
  eval = import <nixpkgs/nixos/lib/eval-config.nix> {
    system = builtins.currentSystem;
    modules = [ __CONFIG_FILE__ ];
  };
  lib = eval.pkgs.lib;
  isOpt = v: builtins.isAttrs v && (v._type or "") == "option";
  walk = prefix: node:
    if isOpt node then
      (if lib.hasSuffix ".enable" prefix then [ prefix ] else [])
    else if builtins.isAttrs node then
      let r = builtins.tryEval (lib.mapAttrsToList
        (n: v: walk (if prefix == "" then n else "${prefix}.${n}") v) node);
      in if r.success then lib.concatLists r.value else []
    else [];
in walk "" eval.options
NIXEOF
    sed -i "s|__CONFIG_FILE__|$CONFIG_FILE|" "$walker"
    out=$(nix-instantiate --eval --strict --json "$walker" 2>/tmp/nixi-eval.log) \
      || { echo "eval failed, see /tmp/nixi-eval.log - keeping the old cache if there is one" >&2; rm -f "$walker"; return 1; }
  fi

  rm -f "$walker"
  echo "$out" | grep -oE '"[^"]+"' | tr -d '"' | sort -u > "$OPTIONS_CACHE"
  echo "cached $(wc -l < "$OPTIONS_CACHE") options"
}

match_options() {
  local pkg="$1"
  [[ -f "$OPTIONS_CACHE" ]] || return 1
  awk -F. -v p="$pkg" '$(NF-1) == p' "$OPTIONS_CACHE"
}

prompt_option_choice() {
  local pkg="$1"; shift
  local -a opts=("$@")
  echo "found more than one possible option for '$pkg':" >&2
  local i=1 o
  for o in "${opts[@]}"; do
    echo "  $i) $o = true;" >&2
    i=$((i+1))
  done
  echo "  0) just install $pkg normally" >&2
  local choice
  read -rp "pick one [0-${#opts[@]}]: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#opts[@]} )); then
    echo "${opts[$((choice-1))]}"
  fi
}

do_rebuild() {
  if using_flakes; then
    nixos-rebuild switch --flake "/etc/nixos#$(hostname)" --option experimental-features "nix-command flakes"
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

  local name
  name=$(bare "$pkg")

  local -a candidates=()
  if [[ -f "$OPTIONS_CACHE" ]]; then
    while IFS= read -r line; do candidates+=("$line"); done < <(match_options "$name")
  fi
  if [[ ${#candidates[@]} -eq 0 && -n "${KNOWN_OPTIONS[$name]:-}" ]]; then
    candidates=("${KNOWN_OPTIONS[$name]}")
  fi

  local opt=""
  if [[ ${#candidates[@]} -eq 1 ]] && ! option_set "${candidates[0]}"; then
    read -rp "$name has a real NixOS option (${candidates[0]} = true;) that does more than just installing the binary - use that instead? [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]] && opt="${candidates[0]}"
  elif [[ ${#candidates[@]} -gt 1 ]]; then
    opt=$(prompt_option_choice "$name" "${candidates[@]}")
  fi

  [[ -n "$opt" ]] && { add_option "$opt"; return; }

  local backup start end
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

  local name
  name=$(bare "$pkg")

  if pkg_installed "$pkg"; then
    local backup start end tmp
    backup=$(backup_config)
    read -r start end <<<"$(block_bounds)"
    tmp=$(mktemp)
    awk -v s="$start" -v e="$end" -v p="$name" '
      NR>s && NR<e {
        line=$0
        trimmed=line
        sub(/^[[:space:]]*/,"",trimmed)
        if (trimmed ~ /^#/ || trimmed == "") { print line; next }
        stripped=line
        sub(/#.*/,"",stripped)
        n=split(stripped, words, /[[:space:]]+/)
        found=0
        for (i=1;i<=n;i++){ w=words[i]; if (w=="") continue; bw=w; sub(/^pkgs\./,"",bw); if (bw==p){found=1;break} }
        if (!found){ print line; next }
        match(line,/^[[:space:]]*/); indent=substr(line,RSTART,RLENGTH)
        out=""
        for (i=1;i<=n;i++){ w=words[i]; if (w=="") continue; bw=w; sub(/^pkgs\./,"",bw); if (bw==p) continue; out=(out=="")?w:out" "w }
        if (out=="") next
        print indent out
        next
      }
      { print }
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    echo "removed $name"
    rebuild_or_rollback "$backup"
    return
  fi

  local -a candidates=()
  if [[ -f "$OPTIONS_CACHE" ]]; then
    while IFS= read -r line; do candidates+=("$line"); done < <(match_options "$name")
  fi
  if [[ ${#candidates[@]} -eq 0 && -n "${KNOWN_OPTIONS[$name]:-}" ]]; then
    candidates=("${KNOWN_OPTIONS[$name]}")
  fi

  local opt="" c
  for c in "${candidates[@]}"; do
    option_set "$c" && { opt="$c"; break; }
  done

  if [[ -n "$opt" ]]; then
    read -rp "'$name' isn't in systemPackages, but $opt = true; is set - remove that instead? [Y/n] " reply
    if [[ -z "$reply" || "$reply" =~ ^[Yy] ]]; then
      remove_option "$opt"
      return
    fi
  fi

  echo "'$pkg' isn't in there"
  exit 0
}

cmd_upgrade() {
  require_root
  if using_flakes; then
    echo "updating flake inputs..."
    nix --extra-experimental-features "nix-command flakes" flake update --flake /etc/nixos
  else
    echo "updating channels..."
    nix-channel --update
  fi
  echo "rebuilding..."
  do_rebuild
}

cmd_rollback() {
  require_root
  local target="${1:-}"
  case "$target" in
    "")
      echo "rolling back to the previous generation..."
      nixos-rebuild switch --rollback
      ;;
    list)
      nix-env --list-generations --profile /nix/var/nix/profiles/system
      ;;
    *)
      echo "switching to generation $target..."
      nix-env --profile /nix/var/nix/profiles/system --switch-generation "$target"
      /nix/var/nix/profiles/system/bin/switch-to-configuration switch
      ;;
  esac
}

cmd_list() {
  require_config
  local start end
  read -r start end <<<"$(block_bounds)"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" | sed -E '/^[[:space:]]*(#.*)?$/d'
}

cmd_fmt() {
  require_root
  require_config
  local backup start end tmp
  backup=$(backup_config)
  read -r start end <<<"$(block_bounds)"
  tmp=$(mktemp)
  sed -n "1,${start}p" "$CONFIG_FILE" > "$tmp"
  sed -n "$((start+1)),$((end-1))p" "$CONFIG_FILE" \
    | sed -E 's/#.*//' \
    | tr -s '[:space:]' '\n' \
    | sed -E 's/^pkgs\.//' \
    | grep -v '^[[:space:]]*$' \
    | sort -u \
    | sed 's/^/    /' >> "$tmp"
  sed -n "${end},\$p" "$CONFIG_FILE" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  echo "formatted, rebuilding to make sure nothing broke..."
  rebuild_or_rollback "$backup"
}

cmd_search() {
  local term="${1:-}"
  [[ -n "$term" ]] || usage
  echo "searching nixpkgs for '$term'..."

  local results=""
  if using_flakes; then
    results=$(nix search nixpkgs "$term" --extra-experimental-features "nix-command flakes" 2>/dev/null \
      | awk '/^\* / { path=$2; sub(/^legacyPackages\.[^.]+\./, "", path); print path }')
  fi
  if [[ -z "$results" ]]; then
    results=$(nix-env -qaP --description 2>/dev/null | grep -i -- "$term" || true)
  fi
  if [[ -z "$results" ]]; then
    echo "no matches."
    return
  fi

  if command -v fzf >/dev/null 2>&1; then
    local pick
    pick=$(echo "$results" | fzf --prompt="install> " | awk '{print $1}' | sed -E 's#^nixos\.##; s#^nixpkgs\.##')
    [[ -n "$pick" ]] && cmd_install "$pick"
  else
    echo "$results"
  fi
}

dispatch() {
  case "${1:-}" in
    install)         shift; cmd_install "${1:-}" ;;
    remove)          shift; cmd_remove "${1:-}" ;;
    upgrade)         cmd_upgrade ;;
    refresh-options) cmd_refresh_options ;;
    fmt)             cmd_fmt ;;
    rollback)        shift; cmd_rollback "${1:-}" ;;
    list)            cmd_list ;;
    search)          shift; cmd_search "${1:-}" ;;
    *)               usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  dispatch "$@"
fi
