#!/usr/bin/env bash
set -euo pipefail
# setup.sh — Complete Fork-on-Wine setup
# Creates a Wine prefix, installs .NET 4.7.2, Fork 2.16.1, fonts,
# WinRT contracts, NaturalLanguage6 stub, Mono DLL map patch,
# Wine registry overrides, and gitconfig with line ending overrides.
#
# Prerequisites:
#   - winehq-staging installed from WineHQ repos
#   - mingw-w64 (sudo apt install mingw-w64)
#   - Python 3 with dnfile (pip install dnfile)
#   - winetricks at ~/.local/bin/winetricks-latest
#
# Usage: ./setup.sh [WINEPREFIX]

WINEPREFIX="${1:-$HOME/.wine-fork}"
export WINEPREFIX
export WINEARCH=win64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORK_VERSION="2.16.1"
FORK_INSTALLER="/tmp/Fork-${FORK_VERSION}.exe"

if [[ ! -f "$FORK_INSTALLER" ]]; then
    echo "=== Downloading Fork $FORK_VERSION ==="
    curl -fL -o "$FORK_INSTALLER" "https://cdn.fork.dev/win/Fork-${FORK_VERSION}.exe"
    echo "  Downloaded to $FORK_INSTALLER"
    echo ""
fi

WINETRICKS="${WINETRICKS:-$HOME/.local/bin/winetricks-latest}"
if [[ ! -x "$WINETRICKS" ]]; then
    echo "ERROR: winetricks not found at $WINETRICKS"
    echo "Install: curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -o $WINETRICKS && chmod +x $WINETRICKS"
    exit 1
fi

if ! command -v x86_64-w64-mingw32-gcc &>/dev/null; then
    echo "ERROR: mingw-w64 not found. Install: sudo apt install mingw-w64"
    exit 1
fi

echo "=== Creating Wine prefix: $WINEPREFIX ==="
if [[ -d "$WINEPREFIX" ]]; then
    echo "ERROR: $WINEPREFIX already exists. Remove it first or choose a different prefix."
    exit 1
fi

wineboot -u
echo ""

# ---------- Step 1: Windows 10 mode + fonts ----------
echo "=== Installing fonts ==="
"$WINETRICKS" -q win10 corefonts tahoma consolas

# Segoe UI → Tahoma font substitution
wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v 'Segoe UI' /t REG_SZ /d 'Tahoma' /f 2>/dev/null
wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v 'Segoe UI Semibold' /t REG_SZ /d 'Tahoma' /f 2>/dev/null
wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v 'Segoe UI Light' /t REG_SZ /d 'Tahoma' /f 2>/dev/null
echo "  Fonts installed, Segoe UI mapped to Tahoma"
echo ""

# ---------- Step 2: .NET Framework 4.7.2 ----------
echo "=== Installing .NET Framework 4.7.2 ==="
"$WINETRICKS" -q dotnet472
echo ""

# ---------- Step 3: Install Fork ----------
echo "=== Installing Fork 2.16.1 ==="
wine "$FORK_INSTALLER" --silent
echo "  Waiting for installer to finish..."
wineserver -w
echo ""

FORK_DIR="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Fork/current"
if [[ ! -f "$FORK_DIR/Fork.exe" ]]; then
    echo "ERROR: Fork.exe not found at $FORK_DIR"
    exit 1
fi
echo "  Fork installed to: $FORK_DIR"
echo ""

# ---------- Step 4: WinRT SDK contracts ----------
echo "=== Installing WinRT SDK contracts ==="
TMPDIR_SDK="$(mktemp -d)"
curl -sL -o "$TMPDIR_SDK/sdk-contracts.nupkg" \
    "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.Contracts/10.0.22621.755"
unzip -o "$TMPDIR_SDK/sdk-contracts.nupkg" -d "$TMPDIR_SDK/sdk-contracts" > /dev/null

count=0
for f in "$TMPDIR_SDK/sdk-contracts/ref/netstandard2.0/"*.winmd; do
    base=$(basename "$f" .winmd)
    cp "$f" "$FORK_DIR/${base}.dll"
    count=$((count + 1))
done
echo "  Copied $count WinMD contract DLLs"

# System.Runtime.WindowsRuntime
curl -sL -o "$TMPDIR_SDK/winrt-runtime.nupkg" \
    "https://www.nuget.org/api/v2/package/System.Runtime.WindowsRuntime/4.7.0"
unzip -o "$TMPDIR_SDK/winrt-runtime.nupkg" -d "$TMPDIR_SDK/winrt-runtime" > /dev/null
cp "$TMPDIR_SDK/winrt-runtime/lib/netstandard2.0/System.Runtime.WindowsRuntime.dll" "$FORK_DIR/"
echo "  Installed System.Runtime.WindowsRuntime.dll"
rm -rf "$TMPDIR_SDK"
echo ""

# ---------- Step 5: NaturalLanguage6 stub ----------
echo "=== Building NaturalLanguage6.dll stub ==="
TMPDIR_NL6="$(mktemp -d)"
cat > "$TMPDIR_NL6/nl6stub.c" << 'CEOF'
#include <windows.h>
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID p) { return TRUE; }
__declspec(dllexport) HRESULT WINAPI NlLoad(void) { return S_OK; }
__declspec(dllexport) void    WINAPI NlUnload(void) { }
__declspec(dllexport) HRESULT WINAPI NlGetClassObject(void *a, void *b, void *c) { return E_NOINTERFACE; }
__declspec(dllexport) HRESULT WINAPI NlCreateHyphenator(void *a, void **b) { if(b)*b=NULL; return E_NOINTERFACE; }
__declspec(dllexport) HRESULT WINAPI NlDestroyHyphenator(void *a) { return S_OK; }
__declspec(dllexport) HRESULT WINAPI NlHyphenate(void *a, void *b, int c, int d, void *e) { return S_OK; }
CEOF
x86_64-w64-mingw32-gcc -shared -o "$TMPDIR_NL6/NaturalLanguage6.dll" "$TMPDIR_NL6/nl6stub.c" -Wl,--kill-at

# Install to 3 locations
cp "$TMPDIR_NL6/NaturalLanguage6.dll" "$FORK_DIR/"
cp "$TMPDIR_NL6/NaturalLanguage6.dll" "$WINEPREFIX/drive_c/windows/system32/"
MONO_LIB="$WINEPREFIX/drive_c/windows/mono/mono-2.0/lib/x86_64"
if [[ -d "$MONO_LIB" ]]; then
    cp "$TMPDIR_NL6/NaturalLanguage6.dll" "$MONO_LIB/"
    echo "  Installed to Fork dir, system32, and Mono lib"
else
    echo "  Installed to Fork dir and system32 (Mono lib dir not found)"
fi
rm -rf "$TMPDIR_NL6"

# Wine DLL override
wine reg add 'HKCU\Software\Wine\DllOverrides' /v NaturalLanguage6 /t REG_SZ /d native /f 2>/dev/null
echo "  Registered NaturalLanguage6 DLL override"
echo ""

# ---------- Step 6: Mono DLL map patch ----------
echo "=== Patching PresentationFramework.dll.config ==="
PF_CONFIG="$WINEPREFIX/drive_c/windows/mono/mono-2.0/lib/mono/gac/PresentationFramework/4.0.0.0__31bf3856ad364e35/PresentationFramework.dll.config"
if [[ -d "$(dirname "$PF_CONFIG")" ]]; then
    cat > "$PF_CONFIG" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
	<dllmap dll="PresentationNative_cor3.dll" target="$mono_libdir\x86\PresentationNative_cor3.dll" os="windows" cpu="x86">
		<dllentry dll="NaturalLanguage6" name="NlLoad" target="NlLoad"/>
		<dllentry dll="NaturalLanguage6" name="NlUnload" target="NlUnload"/>
		<dllentry dll="NaturalLanguage6" name="NlGetClassObject" target="NlGetClassObject"/>
		<dllentry dll="NaturalLanguage6" name="NlCreateHyphenator" target="NlCreateHyphenator"/>
		<dllentry dll="NaturalLanguage6" name="NlDestroyHyphenator" target="NlDestroyHyphenator"/>
		<dllentry dll="NaturalLanguage6" name="NlHyphenate" target="NlHyphenate"/>
	</dllmap>
	<dllmap dll="PresentationNative_cor3.dll" target="$mono_libdir\x86_64\PresentationNative_cor3.dll" os="windows" cpu="x86-64">
		<dllentry dll="NaturalLanguage6" name="NlLoad" target="NlLoad"/>
		<dllentry dll="NaturalLanguage6" name="NlUnload" target="NlUnload"/>
		<dllentry dll="NaturalLanguage6" name="NlGetClassObject" target="NlGetClassObject"/>
		<dllentry dll="NaturalLanguage6" name="NlCreateHyphenator" target="NlCreateHyphenator"/>
		<dllentry dll="NaturalLanguage6" name="NlDestroyHyphenator" target="NlDestroyHyphenator"/>
		<dllentry dll="NaturalLanguage6" name="NlHyphenate" target="NlHyphenate"/>
	</dllmap>
</configuration>
EOF
    echo "  Patched Mono DLL map for NaturalLanguage6"
else
    echo "  WARNING: PresentationFramework GAC dir not found, skipping DLL map patch"
fi
echo ""

# ---------- Step 7: Patch Fork.exe ----------
echo "=== Patching Fork.exe ==="
python3 "$SCRIPT_DIR/patch_fork.py" "$FORK_DIR/Fork.exe"
echo ""

# ---------- Step 8: Git configuration ----------
echo "=== Configuring Git for Wine ==="
WINE_GITCONFIG="$WINEPREFIX/drive_c/users/$USER/.gitconfig"
cat > "$WINE_GITCONFIG" << GCEOF
[include]
	path = Z:/home/$USER/.gitconfig

[core]
	autocrlf = false
	eol = lf
	filemode = false
GCEOF
echo "  Created Wine .gitconfig with include and line ending overrides"
echo ""

# ---------- Step 9: Git LFS repo for update tracking ----------
echo "=== Initializing git LFS repo for update tracking ==="
FORK_PARENT="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Fork"
cd "$FORK_PARENT"
git init
git config core.filemode false
git lfs install
git lfs track "*.dll" "*.exe" "*.config" "*.winmd" "*.json"

cat > .gitignore << 'EOF'
gitInstance/
packages/
logs/
velopack.log
EOF

git add -A
git commit -m "Fork 2.16.1 patched for Wine (7 patches applied)"
echo ""

# ---------- Done ----------
echo "=========================================="
echo "Fork 2.16.1 setup complete!"
echo ""
echo "Launch with:"
echo "  WINEPREFIX=\"$WINEPREFIX\" WINEDLLOVERRIDES=\"NaturalLanguage6=n\" WINEDEBUG=-all wine \"$FORK_DIR/Fork.exe\""
echo ""
echo "Or install the launch script:"
echo "  cp \"$SCRIPT_DIR/fork\" ~/.local/bin/fork"
echo "=========================================="
