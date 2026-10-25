#!/usr/bin/env bash
# ==============================================================================
# Gamescope Verification & Performance Test Script
# System: Ubuntu 24.04 (Z890PW) | RTX 5090 | 1440p @ 240Hz (DP-4)
# ==============================================================================
set -uo pipefail

# ------------------------------------------------------------------------------
# Locate Gamescope binary (prefer installed system binary with CAP_SYS_NICE)
# ------------------------------------------------------------------------------
GAMESCOPE_BIN=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v gamescope >/dev/null 2>&1; then
    GAMESCOPE_BIN="$(command -v gamescope)"
elif [ -x "$SCRIPT_DIR/build/src/gamescope" ]; then
    GAMESCOPE_BIN="$SCRIPT_DIR/build/src/gamescope"
elif [ -x "./build/src/gamescope" ]; then
    GAMESCOPE_BIN="./build/src/gamescope"
fi

# ------------------------------------------------------------------------------
# Locate vkcube binary (check local Vulkan SDK first, auto-detect the path)
# ------------------------------------------------------------------------------
VKCUBE_BIN=""
VULKAN_SDK_PATH="${VULKAN_SDK:-}"
if [ -z "$VULKAN_SDK_PATH" ] || [ ! -x "$VULKAN_SDK_PATH/bin/vkcube" ]; then
    VULKAN_SDK_PATH=""
    for cand in \
        "$HOME"/vulkansdk-*/*/x86_64 \
        "$HOME"/vulkansdk-*/x86_64 \
        /opt/vulkansdk/*/*/x86_64 \
        /opt/vulkansdk/*/x86_64; do
        if [ -x "$cand/bin/vkcube" ]; then VULKAN_SDK_PATH="$cand"; break; fi
    done
fi

if [ -n "$VULKAN_SDK_PATH" ] && [ -x "${VULKAN_SDK_PATH}/bin/vkcube" ]; then
    VKCUBE_BIN="${VULKAN_SDK_PATH}/bin/vkcube"
    export PATH="${VULKAN_SDK_PATH}/bin:$PATH"
    export LD_LIBRARY_PATH="${VULKAN_SDK_PATH}/lib:${LD_LIBRARY_PATH:-}"
    export VK_LAYER_PATH="${VULKAN_SDK_PATH}/share/vulkan/explicit_layer.d:${VK_LAYER_PATH:-}"
elif command -v vkcube >/dev/null 2>&1; then
    VKCUBE_BIN="$(command -v vkcube)"
fi

echo "============================================================"
echo "          Gamescope Build Verification Tool"
echo "============================================================"

# ------------------------------------------------------------------------------
# Binary check
# ------------------------------------------------------------------------------
if [ -n "$GAMESCOPE_BIN" ]; then
    echo "[✓] Found Gamescope: $GAMESCOPE_BIN"
    "$GAMESCOPE_BIN" --version 2>/dev/null || true
else
    echo "[✗] Gamescope binary not found!"
    exit 1
fi

# ------------------------------------------------------------------------------
# Capabilities check
# ------------------------------------------------------------------------------
CAP_STATUS=$(getcap "$GAMESCOPE_BIN" 2>/dev/null || true)
if [ -n "$CAP_STATUS" ]; then
    echo "[✓] Real-time capabilities: $CAP_STATUS"
else
    echo "[!] No CAP_SYS_NICE capability set on $GAMESCOPE_BIN"
    echo "    To enable real-time scheduling (SCHED_FIFO), run:"
    echo "      sudo setcap 'cap_sys_nice=eip' $GAMESCOPE_BIN"
fi

# ------------------------------------------------------------------------------
# RPATH check
# ------------------------------------------------------------------------------
RPATH=$(readelf -d "$GAMESCOPE_BIN" 2>/dev/null | grep -i 'rpath\|runpath' | head -1 || echo "N/A")
echo "[i] RPATH: $RPATH"

# ------------------------------------------------------------------------------
# Wayland library check
# ------------------------------------------------------------------------------
echo "[i] Linked wayland libraries:"
ldd "$GAMESCOPE_BIN" 2>/dev/null | grep wayland || echo "    (none found)"

# ------------------------------------------------------------------------------
# vkcube check
# ------------------------------------------------------------------------------
if [ -n "$VKCUBE_BIN" ]; then
    echo "[✓] Found vkcube: $VKCUBE_BIN"
else
    echo "[!] vkcube not found"
fi

# ------------------------------------------------------------------------------
# Test runner: launch gamescope with vkcube for N seconds, capture FPS
# ------------------------------------------------------------------------------
run_test() {
    local label="$1"; shift
    local duration="${1:-10}"; shift
    local args=("$@")
    local log="/tmp/verify_${label}.log"
    local frametime_log="/tmp/verify_${label}_frametime.csv"

    echo ""
    echo "------------------------------------------------------------"
    echo "[TEST] $label"
    echo "       Command: $GAMESCOPE_BIN ${args[*]} -r 240 -- $VKCUBE_BIN"
    echo "------------------------------------------------------------"

    pkill -f "build/src/[g]amescope" 2>/dev/null || true
    pkill -f "/usr/local/bin/gamescope" 2>/dev/null || true
    sleep 2
    rm -f "$log" "$frametime_log"

    # Launch gamescope in background
    setsid "$GAMESCOPE_BIN" "${args[@]}" -r 240 -- "$VKCUBE_BIN" > "$log" 2>&1 &
    local gspid=$!

    # Wait for vkcube to appear
    local vkpid=""
    for i in $(seq 1 30); do
        vkpid=$(pgrep -f "bin/[v]kcube" | head -1)
        [ -n "$vkpid" ] && break
        [ -n "$gspid" ] && kill -0 "$gspid" 2>/dev/null || { echo "  gamescope exited early:"; grep -aiE "error|fail|CAP_SYS_NICE" "$log" | tail -5; return 1; }
        sleep 1
    done

    if [ -z "$vkpid" ]; then
        echo "  [✗] vkcube never started"
        kill -TERM "$gspid" 2>/dev/null || true
        return 1
    fi

    echo "  [✓] gamescope PID=$gspid, vkcube PID=$vkpid"

    # Check for CAP_SYS_NICE warning
    if grep -qi "No CAP_SYS_NICE" "$log" 2>/dev/null; then
        echo "  [!] Warning: CAP_SYS_NICE not active (real-time scheduling disabled)"
    else
        echo "  [✓] CAP_SYS_NICE active (no warning in log)"
    fi

    # Run for the specified duration
    sleep "$duration"

    # Capture frametimes from vkcube if available
    if [ -f /tmp/vkcube_frametimes.csv ]; then
        cp /tmp/vkcube_frametimes.csv "$frametime_log" 2>/dev/null || true
    fi

    # Stop gamescope
    kill -TERM "$gspid" 2>/dev/null || true
    wait "$gspid" 2>/dev/null || true
    pkill -f "build/src/[g]amescope" 2>/dev/null || true
    pkill -f "/usr/local/bin/gamescope" 2>/dev/null || true
    sleep 1

    # Check if gamescope stayed alive
    if pgrep -f "build/src/[g]amescope" >/dev/null 2>&1 || pgrep -f "/usr/local/bin/gamescope" >/dev/null 2>&1; then
        echo "  [✓] gamescope still running after test"
        pkill -f "build/src/[g]amescope" 2>/dev/null || true
        pkill -f "/usr/local/bin/gamescope" 2>/dev/null || true
    else
        echo "  [i] gamescope exited (expected after test duration)"
    fi

    # Show key log lines
    echo "  [i] Key log output:"
    grep -aiE "Info|Warning|Error|CAP_SYS_NICE|SCHED|WSI|wayland|SDL" "$log" 2>/dev/null | head -10 || true

    return 0
}

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------
choice="${1:-}"

if [ -z "$choice" ]; then
    echo ""
    echo "Select a test mode:"
    echo "  1) Verify binary (capabilities, RPATH, libraries)"
    echo "  2) Live CAP_SYS_NICE check (windowed vkcube 1280x720, ~10s)"
    echo "  3) Windowed fullscreen (1920x1080 -> 2560x1440, -f)"
    echo "  4) Exclusive fullscreen (2560x1440 @ 240Hz, -f --fullscreen)"
    echo "  5) FSR upscaling (720p -> 1440p, -F fsr)"
    echo "  6) Immediate flips (--immediate-flips flag)"
    echo "  7) All tests (full verification suite)"
    echo "  8) CS2 launch options guide"
    echo "  9) Native drawing (vkcube directly, no gamescope)"
    echo "  q) Quit"
    echo ""
    read -rp "Enter choice [1-9, q]: " choice
fi

case "$choice" in
    1|verify|binary)
        echo ""
        echo "[+] Binary verification complete (see output above)"
        ;;
    2|windowed|cap)
        run_test "windowed" 10 -w 1280 -h 720 -W 1280 -H 720
        ;;
    3|windowed-fullscreen|wf)
        run_test "windowed-fullscreen" 10 -w 1920 -h 1080 -W 2560 -H 1440 -f
        ;;
    4|exclusive-fullscreen|efs)
        run_test "exclusive-fullscreen" 10 -w 2560 -h 1440 -W 2560 -H 1440 -f --fullscreen
        ;;
    5|fsr)
        run_test "fsr-upscale" 10 -w 1280 -h 720 -W 2560 -H 1440 -F fsr --fsr-sharpness 2
        ;;
    6|immediate-flips|iflips)
        run_test "immediate-flips" 10 -w 1920 -h 1080 -W 2560 -H 1440 --immediate-flips -f
        ;;
    7|all|full)
        echo ""
        echo "============================================================"
        echo "          Running Full Verification Suite"
        echo "============================================================"
        run_test "windowed" 8 -w 1280 -h 720 -W 1280 -H 720
        run_test "windowed-fullscreen" 8 -w 1920 -h 1080 -W 2560 -H 1440 -f
        run_test "exclusive-fullscreen" 8 -w 2560 -h 1440 -W 2560 -H 1440 -f --fullscreen
        run_test "fsr-upscale" 8 -w 1280 -h 720 -W 2560 -H 1440 -F fsr --fsr-sharpness 2
        run_test "immediate-flips" 8 -w 1920 -h 1080 -W 2560 -H 1440 --immediate-flips -f
        echo ""
        echo "============================================================"
        echo "          Full Verification Suite Complete"
        echo "============================================================"
        echo "Frametime CSVs (if captured): /tmp/verify_*_frametime.csv"
        echo "Logs: /tmp/verify_*.log"
        ;;
    8|cs2)
        echo ""
        echo "============================================================"
        echo "     Counter-Strike 2 (CS2) with Gamescope Configuration"
        echo "============================================================"
        echo ""
        echo "Recommended Steam Launch Options for CS2 (2560x1440 @ 240Hz):"
        echo "------------------------------------------------------------"
        echo "gamescope -w 2560 -h 1440 -W 2560 -H 1440 -r 240 --prefer-output DP-4"
        echo "    --force-grab-cursor --fullscreen -- %command% -vulkan"
        echo "------------------------------------------------------------"
        echo ""
        echo "For Competitive Stretched 4:3 (e.g. 1920x1440 upscaled to 1440p):"
        echo "------------------------------------------------------------"
        echo "gamescope -w 1920 -h 1440 -W 2560 -H 1440 -S stretch -r 240"
        echo "    --prefer-output DP-4 --force-grab-cursor --fullscreen"
        echo "    -- %command% -vulkan"
        echo ""
        echo "Key flags:"
        echo "  --rt              : Real-time scheduling (requires CAP_SYS_NICE)"
        echo "  --immediate-flips : Bypass vsync queuing for minimum latency"
        echo "  --backend sdl     : Use SDL backend"
        echo "  --prefer-vk-device: Select specific Vulkan device (PCI ID)"
        echo "  -f                : Fullscreen window"
        echo "  --fullscreen      : Exclusive fullscreen"
        echo "  --force-grab-cursor : Prevent mouse escape on multi-monitor"
        echo "  -r 240            : Lock to 240Hz"
        echo "  -o 60             : Output at 60Hz (if needed)"
        ;;
    9|native|native-draw)
        echo ""
        echo "============================================================"
        echo "          Native Drawing (vkcube directly, no gamescope)"
        echo "============================================================"
        echo ""
        echo "Running vkcube directly (baseline, no gamescope compositor)..."
        echo "Command: $VKCUBE_BIN --c 300"
        echo ""
        "$VKCUBE_BIN" --c 300 2>&1 | tail -5
        echo ""
        echo "[✓] Native drawing test complete"
        ;;
    q|Q|quit|exit)
        echo "Exiting."
        exit 0
        ;;
    *)
        echo "Invalid selection: $choice"
        exit 1
        ;;
esac
