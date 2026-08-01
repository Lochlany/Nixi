# Nixi
Imperative package management for NixOS, install/remove packages like apt/pacman, but it edits your `configuration.nix` (or updates flake inputs in the newer version) and runs `nixos-rebuild switch` behind the scenes.
> **Warning:** this edits `/etc/nixos/configuration.nix` as root via `sudo`. if a rebuild fails it automaticaly restores your previous config from bcakup, so your system stays on the last working generation.
## Setup
1. Clone the repo:
```bash
   git clone https://github.com/Lochlany/Nixi.git
   cd Nixi
```
2. Install the script:
```bash
   sudo cp nixi.sh /usr/local/bin/nixi
   sudo chmod +x /usr/local/bin/nixi
```
3. Add an alias (sudos PATH doesnt include `/usr/local/bin` on NixOS by default):
```bash
   echo "alias nixi='sudo /usr/local/bin/nixi'" >> ~/.bashrc
   source ~/.bashrc
```
4. Vreify it works:
```bash
   nixi list
```
**requirement:** your `configuration.nix` needs a standard `environment.systemPackages = with pkgs; [ ... ];` block (the default from `nixos-generate-config`). if its missing, add an empty one first:
```nix
environment.systemPackages = with pkgs; [
];
```
## Usage
```bash
sudo nixi install firefox     # add a package and rebuild
sudo nixi remove firefox      # remove a package and rebuild
sudo nixi upgrade             # update flake inputs (or channels) and rebuild
nixi list                     # show installed packages
nixi search browser           # search nixpkgs
```
`nixi upgrade` runs `nix flake update` and rebuilds if your on a flake based config (`/etc/nixos/flake.nix` exists), otherwise falls back to `nix-channel --update`.
if you have [fzf](https://github.com/junegunn/fzf) installed, `nixi search` lets you pick a result interactivly and installs it right away instead of just printing matches.
also, `pkgs.foo` and `foo` are treated as the same package, so it doesnt matter which one you type for install/remove.
## Updates
Nixi V2:
added `nixi upgrade`, flake support, and fzf search. rebuilds now use `--flake` automatically if youve got a `flake.nix`, otherwise it just does the old channel update. nothing else changed behavior wise, still backs up before every rebuild and rolls back if somthing breaks.
