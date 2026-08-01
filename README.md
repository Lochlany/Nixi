# Nixi
Makes NixOS feel imperative.


Imperative package management for NixOS — install/remove packages like apt/pacman, but it edits your configuration.nix and runs nixos-rebuild switch behind the scenes

## setup

1. clone the repo and move into it:
```bash
   git clone https://github.com/<your-username>/nixi.git
   cd nixi
```

2. install the script:
```bash
   sudo cp nixi.sh /usr/local/bin/nixi
   sudo chmod +x /usr/local/bin/nixi
```

3. add an alias so you dont need to type the full path (because sudos PATH doesnt include `/usr/local/bin` on NixOS by default):
```bash
   echo "alias nixi='sudo /usr/local/bin/nixi'" >> ~/.bashrc
   source ~/.bashrc
```

4. verify it works:
```bash
   nixi list
```

> **requirement:** your `/etc/nixos/configuration.nix` must have a standard `environment.systemPackages = with pkgs; [ ... ];` block (the default from `nixos-generate-config`). if it doesnt exist yet, add an empty one first in order for it to work.
>
> There is a little detection just incase anything goes wrong it will revert to the original coinfiguration so your pc is unaffected.
