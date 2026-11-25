# Do not use this


This was an interesting experiment but was a bad idea overall. Just use [sourcegit](https://github.com/sourcegit-org/sourcegit). It is close enough to Fork that you will know how to use it.

# fork-wine-setup

Scripts to run [Fork](https://git-fork.com) 2.16.1 on Linux under Wine.

> **Note:** Fork is commercial software ($49.99 one-time). You need a valid license from
> [git-fork.com](https://git-fork.com). This repo provides interoperability patches and setup
> scripts — it does not include or redistribute Fork itself.

## Prerequisites

- Pop!_OS 22.04 / Ubuntu (or similar apt-based distro)
- `winehq-staging` from WineHQ repos
- `mingw-w64` (`sudo apt install mingw-w64`)
- Python 3 with `dnfile` (`pip install dnfile`)
- `winetricks` at `~/.local/bin/winetricks-latest`

## Quick start

```bash
# One-time: get winetricks
curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
  -o ~/.local/bin/winetricks-latest && chmod +x ~/.local/bin/winetricks-latest

# Run the full setup (creates ~/.wine-fork)
./setup.sh

# Install the launch script
cp fork ~/.local/bin/fork && chmod +x ~/.local/bin/fork

# Launch Fork
fork
```

## Files

| File | Description |
|------|-------------|
| `setup.sh` | Complete setup: prefix, .NET, Fork install, contracts, stubs, patches, gitconfig |
| `patch_fork.py` | Binary patcher for Fork.exe (7 methods) |
| `fork` | Launch script for `~/.local/bin/` |

## What the setup does

1. Creates a clean 64-bit Wine prefix
2. Installs fonts (corefonts, Tahoma, Consolas) + Segoe UI substitution
3. Installs .NET Framework 4.7.2
4. Installs Fork 2.16.1
5. Downloads WinRT SDK contracts and System.Runtime.WindowsRuntime
6. Builds and installs NaturalLanguage6.dll stub (mingw)
7. Patches Wine Mono's PresentationFramework DLL map
8. Patches Fork.exe (7 methods for WinRT, FormattedText, spell check)
9. Creates Wine-specific .gitconfig with line ending overrides
10. Initializes a git LFS repo in the Fork directory for update detection
