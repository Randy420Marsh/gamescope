#!/usr/bin/env bash
# ==============================================================================
# Gamescope Build & Install Script for Ubuntu 24.04 (RTX 5090)
# ==============================================================================
# Target version: 3.14.24-24-g5e8fddf5 (commit 5e8fddf5)
#   - This is the newest commit compatible with Ubuntu 24.04's wayland-server 1.22.0
#   - Newer master requires wayland-server >= 1.24.0 which breaks on 24.04
#
# No hardcoded user paths: works from any checkout, finds the Vulkan SDK
# automatically, and prompts to install missing system dependencies.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Repo root = directory containing this script (so it works from anywhere)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "=== Building from: $SCRIPT_DIR ==="

# ------------------------------------------------------------------------------
# Step 0: Check & prompt-install missing system dependencies
# ------------------------------------------------------------------------------
APT_PACKAGES=(
  build-essential        # gcc/g++/make
  meson                  # build system
  ninja-build            # build tool
  patchelf               # RPATH baking
  pkg-config             # dependency discovery
  libcap2-bin            # setcap/getcap (CAP_SYS_NICE)
  libxcb-composite0-dev  # SDL/xcb backend
  libxcb-shape0-dev      # SDL/xcb backend
  libxcb-xfixes0-dev     # SDL/xcb backend
  libxcb-xkb-dev         # XKB via X11
)

# Map apt package -> check command
pkg_installed() {
  case "$1" in
    build-essential)      command -v gcc >/dev/null && command -v g++ >/dev/null ;;
    meson)                command -v meson >/dev/null ;;
    ninja-build)          command -v ninja >/dev/null ;;
    patchelf)             command -v patchelf >/dev/null ;;
    pkg-config)           command -v pkg-config >/dev/null ;;
    libcap2-bin)          command -v setcap >/dev/null && command -v getcap >/dev/null ;;
    libxcb-composite0-dev) pkg-config --exists xcb-composite ;;
    libxcb-shape0-dev)    pkg-config --exists xcb-shape ;;
    libxcb-xfixes0-dev)   pkg-config --exists xcb-xfixes ;;
    libxcb-xkb-dev)       pkg-config --exists xcb-xkb ;;
    *) return 0 ;;
  esac
}

missing=()
for p in "${APT_PACKAGES[@]}"; do
  pkg_installed "$p" || missing+=("$p")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo ""
  echo "Missing system dependencies:"
  printf '  - %s\n' "${missing[@]}"
  echo ""
  if command -v apt-get >/dev/null; then
    read -r -p "Install them now with 'sudo apt-get install'? [Y/n] " ans
    ans=${ans:-Y}
    case "$ans" in
      [Yy]*)
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
        ;;
      *)
        echo "Install manually with:"
        echo "  sudo apt-get install ${missing[*]}"
        exit 1
        ;;
    esac
  else
    echo "apt-get not found. Install manually:"
    echo "  (package manager) install: ${missing[*]}"
    exit 1
  fi
  # Re-check after install
  for p in "${missing[@]}"; do
    pkg_installed "$p" || { echo "ERROR: still missing after install: $p"; exit 1; }
  done
fi
echo "All system dependencies present."

# ------------------------------------------------------------------------------
# Step 0b: Locate the Vulkan SDK (headers >= 1.4.335 required; Ubuntu's stock
#          1.3.275 is too old). Auto-detect; prompt if not found.
# ------------------------------------------------------------------------------
find_vulkan_sdk() {
  local candidate
  # 1. $VULKAN_SDK env var
  if [ -n "${VULKAN_SDK:-}" ] && [ -x "$VULKAN_SDK/bin/vulkaninfo" ]; then
    echo "$VULKAN_SDK"; return 0
  fi
  # 2. Common install locations (user + system). The official SDK tarball
  #    layout nests an extra version dir: vulkansdk-.../<ver>/x86_64.
  #    Detection uses bin/vulkaninfo + include/vulkan (the SDK does not ship
  #    a vulkan.pc file; that comes from system libvulkan-dev).
  for candidate in \
    "$HOME"/vulkansdk-*/*/x86_64 \
    "$HOME"/vulkansdk-*/x86_64 \
    /opt/vulkansdk/*/*/x86_64 \
    /opt/vulkansdk/*/x86_64; do
    if [ -d "$candidate" ] && [ -x "$candidate/bin/vulkaninfo" ] && [ -f "$candidate/include/vulkan/vulkan.h" ]; then
      echo "$candidate"; return 0
    fi
  done
  return 1
}

if VULKAN_SDK_PATH="$(find_vulkan_sdk)"; then
  echo "Vulkan SDK: $VULKAN_SDK_PATH"
else
  echo ""
  echo "Vulkan SDK not found (need >= 1.4.335 headers; Ubuntu's stock 1.3.275 is too old)."
  read -r -p "Enter path to Vulkan SDK (x86_64 dir containing bin/ lib/ include/), or 'skip': " vulk
  if [ "$vulk" = "skip" ]; then
    VULKAN_SDK_PATH=""
    echo "Proceeding without local SDK (works if a new-enough system Vulkan is installed)."
  else
    VULKAN_SDK_PATH="$vulk"
  fi
fi

# Export SDK paths if found
if [ -n "$VULKAN_SDK_PATH" ]; then
  export PKG_CONFIG_PATH="${VULKAN_SDK_PATH}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CPLUS_INCLUDE_PATH="${VULKAN_SDK_PATH}/include:${CPLUS_INCLUDE_PATH:-}"
  export C_INCLUDE_PATH="${VULKAN_SDK_PATH}/include:${C_INCLUDE_PATH:-}"
fi
# Local external libs (optional, e.g. libei)
[ -d "$HOME/.local/lib" ] && export LIBRARY_PATH="$HOME/.local/lib:${LIBRARY_PATH:-}"
[ -d "$HOME/.local/include" ] && export CPLUS_INCLUDE_PATH="$HOME/.local/include:${CPLUS_INCLUDE_PATH:-}" C_INCLUDE_PATH="$HOME/.local/include:${C_INCLUDE_PATH:-}"

# ------------------------------------------------------------------------------
# Step 1: Install required Meson wraps (wayland, wayland-protocols, libdrm,
#         libxkbcommon, pixman, luajit)
# These pull in newer versions than Ubuntu's stock packages.
# ------------------------------------------------------------------------------
meson wrap install wayland 2>/dev/null || true
meson wrap install wayland-protocols 2>/dev/null || true
meson wrap install libdrm 2>/dev/null || true
meson wrap install libxkbcommon 2>/dev/null || true
meson wrap install pixman 2>/dev/null || true
meson wrap install luajit 2>/dev/null || true

# ------------------------------------------------------------------------------
# Step 1b: Initialize git submodules
#   - subprojects/* submodules are auto-cloned by meson, but plain submodules
#     (src/reshade, thirdparty/SPIRV-Headers) are NOT - meson fails with
#     "Include dir reshade/source does not exist" if they're missing.
# ------------------------------------------------------------------------------
if [ -d .git ] || [ -f .git ]; then
  git submodule update --init --recursive || {
    echo "ERROR: git submodule update failed" >&2
    exit 1
  }
fi
[ -d src/reshade/source ] || { echo "ERROR: src/reshade submodule missing (clone with: git clone --recurse-submodules)" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Step 2: Clean previous build
# ------------------------------------------------------------------------------
rm -rf build/

# ------------------------------------------------------------------------------
# Step 3: Configure with Meson
#   - force_fallback_for (set in meson.build default_options) builds
#     wlroots,libliftoff,vkroots,wayland,wayland-protocols from subproject
#     wraps instead of Ubuntu's outdated system packages
#   - RPATH baked to /opt/gamescope-deps/lib so wayland libs are found without
#     LD_LIBRARY_PATH (setcap strips LD_LIBRARY_PATH for security)
# ------------------------------------------------------------------------------
meson setup build/ \
  -Dwayland:documentation=false -Dwayland:tests=false \
  -Dlibxkbcommon:enable-x11=false -Dlibxkbcommon:enable-docs=false -Dlibxkbcommon:enable-tools=false \
  -Dcpp_link_args="-Wl,-rpath,/opt/gamescope-deps/lib" \
  -Dc_link_args="-Wl,-rpath,/opt/gamescope-deps/lib"

# ------------------------------------------------------------------------------
# Step 4: Compile with Ninja
# ------------------------------------------------------------------------------
ninja -C build/

# ------------------------------------------------------------------------------
# Step 5: Copy isolated wayland libraries to /opt/gamescope-deps/lib
#   (wayland-1.26.0 dir name varies; locate it dynamically)
# ------------------------------------------------------------------------------
# Match the wayland 1.x subproject (wayland-1.26.0 style) but NOT
# wayland-protocols-*; its built libs live in the project's src/ dir.
WL_SRC=""
for d in build/subprojects/wayland-1.*/src; do
  [ -d "$d" ] && WL_SRC="$d" && break
done
if [ -n "$WL_SRC" ] && [ -d "$WL_SRC" ]; then
  if [ -w /opt ] || sudo -n true 2>/dev/null; then
    sudo mkdir -p /opt/gamescope-deps/lib
    find "$WL_SRC" -maxdepth 1 -name 'libwayland-*.so*' -type f -exec sudo cp -P {} /opt/gamescope-deps/lib/ \; 2>/dev/null || true
  else
    echo "NOTE: Cannot write to /opt (no sudo). Copy wayland libs manually after build:"
    echo "  sudo mkdir -p /opt/gamescope-deps/lib"
    echo "  find $PWD/$WL_SRC -maxdepth 1 -name 'libwayland-*.so*' -type f -exec sudo cp -P {} /opt/gamescope-deps/lib/ \\;"
  fi
else
  echo "WARNING: built wayland subproject not found under build/subprojects; skipping lib copy."
fi

# ------------------------------------------------------------------------------
# Step 6: System-wide installation (skip subprojects since we build them locally)
# ------------------------------------------------------------------------------
if [ -w /usr/local ] || sudo -n true 2>/dev/null; then
  sudo meson install -C build/ --skip-subprojects

  # Step 7: Re-apply RPATH after meson install (meson may strip it)
  sudo patchelf --set-rpath "/opt/gamescope-deps/lib" /usr/local/bin/gamescope

  # Step 8: Remove the user-level wrapper script
  #   Kernel ignores setcap on #! shell scripts, so ~/.local/bin/gamescope
  #   (a bash wrapper) cannot receive CAP_SYS_NICE. Remove it so the real ELF
  #   binary at /usr/local/bin/gamescope is used instead.
  rm -f ~/.local/bin/gamescope
  hash -r

  # Step 9: Apply CAP_SYS_NICE to the real ELF binary
  #   setcap on a bash #! wrapper is silently ignored by the kernel
  sudo setcap 'cap_sys_nice=eip' /usr/local/bin/gamescope
else
  echo "NOTE: Cannot write to /usr/local (no sudo). Install manually after build:"
  echo "  sudo meson install -C build/ --skip-subprojects"
  echo "  sudo patchelf --set-rpath /opt/gamescope-deps/lib /usr/local/bin/gamescope"
  echo "  rm -f ~/.local/bin/gamescope && hash -r"
  echo "  sudo setcap 'cap_sys_nice=eip' /usr/local/bin/gamescope"
fi

# ------------------------------------------------------------------------------
# Step 10: Verify
# ------------------------------------------------------------------------------
echo ""
echo "=== Verification ==="
if [ -x /usr/local/bin/gamescope ]; then
  echo "Binary: /usr/local/bin/gamescope"
  getcap /usr/local/bin/gamescope 2>/dev/null || echo "setcap not applied (may need ldd check)"
  ldd /usr/local/bin/gamescope | grep wayland-server || echo "wayland-server not linked (check RPATH)"
  echo "RPATH: $(readelf -d /usr/local/bin/gamescope 2>/dev/null | grep -i 'rpath\|runpath' | head -1 || echo 'N/A')"
else
  echo "Build binary: build/src/gamescope"
  readelf -d build/src/gamescope | grep -i 'rpath\|runpath' | head -1 || echo "No RPATH set"
fi

echo ""
echo "=== Manual steps (if sudo was unavailable) ==="
echo "  sudo bash -euo pipefail -c '"
echo "  home=\"\$1\""
echo "  mkdir -p /opt/gamescope-deps/lib"
echo "  find \"\$home\"/gamescope/build/subprojects/wayland-1.*/src -maxdepth 1 -name \"libwayland-*.so*\" -type f -exec cp -P {} /opt/gamescope-deps/lib/ \\;"
echo "  meson install -C \"\$home\"/gamescope/build/ --skip-subprojects"
echo "  patchelf --set-rpath /opt/gamescope-deps/lib /usr/local/bin/gamescope"
echo "  setcap cap_sys_nice=eip /usr/local/bin/gamescope"
echo "  ' _ \"\$HOME\""
echo "  rm -f ~/.local/bin/gamescope && hash -r"
echo "  bash verify_gamescope.sh cap   # live test: expect '[✓] CAP_SYS_NICE active'"

# ------------------------------------------------------------------------------
# Step 11: Prompt to run the live CAP_SYS_NICE test
#   setcap in the filesystem can still be ineffective (noexec mount, FUSE, ...).
#   The only proof is a real gamescope launch that logs without the
#   "No CAP_SYS_NICE" warning (src/main.cpp:794). verify_gamescope.sh 'cap'
#   launches gamescope + vkcube briefly and checks that exact log line.
# ------------------------------------------------------------------------------
echo ""
if command -v gamescope >/dev/null 2>&1 || [ -x /usr/local/bin/gamescope ]; then
  read -rp "Run the live CAP_SYS_NICE test now? Launches gamescope + vkcube for ~10s (Ctrl+C stops early). [Y/n] " ans
  case "$ans" in
    [nN]|[nN][oO])
      echo "Skipping. Run it later with:  bash verify_gamescope.sh cap"
      echo "Look for: [✓] CAP_SYS_NICE active (no warning in log)"
      ;;
    *)
      bash "$(dirname "$0")/verify_gamescope.sh" cap
      ;;
  esac
else
  echo "NOTE: gamescope not on PATH yet (system install skipped). After the manual steps above, run:"
  echo "  bash verify_gamescope.sh cap"
  echo "Look for: [✓] CAP_SYS_NICE active (no warning in log)"
fi
echo ""
echo "=== Performance launch options for CS2 ==="
echo "  gamescope --rt --immediate-flips --backend sdl --prefer-vk-device 10de:2b85"
echo "    -w 2560 -h 1440 -W 2560 -H 1440 -r 240 -o 60 --display-index 0 -f -g"
echo "    --force-grab-cursor --force-windows-fullscreen -- %command% -vulkan"
