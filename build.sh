#!/usr/bin/env bash
# ============================================================================
# DLSS5 Manual Installation Script for MPV (or any DX11/DX12/Vulkan app)
# ============================================================================
# This script simulates the core behaviour of DLSS5oneclick / DLSS5-Feeder
# automatic installer. It downloads every required component and places it
# into the target directory so that DLSS 5 Neural Rendering can be enabled
# via ReShade.
#
# Requirements:
#   - bash, curl, unzip
#   - 7z (p7zip)  ← required to extract ReShade DLL from the official Setup.exe
#
# Usage:
#   ./install_dlss5_mpv.sh /path/to/mpv
#   ./install_dlss5_mpv.sh /path/to/mpv --force   # overwrite existing files
#
# After installation:
#   1. Launch MPV and press Home to open the ReShade overlay
#   2. Go to the Add-ons tab → enable "DLSS 5 Neural Rendering"
#   3. In the Effects list make sure Lumenite_Kernel is above DLSS5_Feed
#   4. Check dlss5-feed.log for "feature ready … DLAA"
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MPV_DIR="${1:-.}"
FORCE=0
[[ "${2:-}" == "--force" ]] && FORCE=1

WORK_DIR=$(mktemp -d)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dlss5-install"
mkdir -p "$CACHE_DIR"

# Marker files used by DLSS5oneclick-style tracking
RESHADE_MARKER="dxgi.dll.dlss5oneclick"
FEEDER_MARKER="dlss5-feed.dlss5oneclick"
DLSS5_ADDON_MARKER="renodx-dlss5.addon64.dlss5oneclick"
DLSSNR_MARKER="nvngx_dlssnr.dll.dlss5oneclick"
DLSS_MARKER="nvngx_dlss.dll.dlss5oneclick"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_step()  { echo -e "\n[STEP] $1"; }
log_info()  { echo "[INFO] $1"; }
log_ok()    { echo "[ OK ] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERR ] $1" >&2; }

cleanup() {
    log_info "Cleaning temporary directory..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Download a file with simple caching
download() {
    local url="$1"
    local dest="$2"
    local name="${3:-$(basename "$dest")}"

    if [[ -f "$dest" && $FORCE -eq 0 ]]; then
        log_info "Using cached file: $(basename "$dest")"
        return 0
    fi

    log_info "Downloading $name ..."
    mkdir -p "$(dirname "$dest")"
    curl -fL --progress-bar -o "$dest" "$url" || {
        log_error "Failed to download: $url"
        return 1
    }
    log_ok "Downloaded: $(basename "$dest")"
}

# Extract a single member from a zip (or from a PE that contains an appended zip)
extract_member() {
    local archive="$1"
    local member="$2"
    local dest="$3"

    mkdir -p "$(dirname "$dest")"

    if command -v 7z &>/dev/null; then
        # 7z can read both normal ZIPs and PE files with an appended ZIP
        7z e -y -so "$archive" "$member" > "$dest" 2>/dev/null && return 0
        # Try wildcard path (some zips have a top-level folder)
        7z e -y -so "$archive" "*/$member" > "$dest" 2>/dev/null && return 0
    fi

    # Fallback for pure ZIP archives
    if command -v unzip &>/dev/null; then
        unzip -p "$archive" "$member" > "$dest" 2>/dev/null && return 0
        # Try to find the member anywhere in the archive
        local found
        found=$(unzip -l "$archive" 2>/dev/null | awk '{print $4}' | grep -i "/${member}$\|${member}$" | head -1)
        if [[ -n "$found" ]]; then
            unzip -p "$archive" "$found" > "$dest" 2>/dev/null && return 0
        fi
    fi

    return 1
}

# Extract whole archive into a directory.
# Prefer 7z: it correctly handles ZIPs that use backslash path separators
# (common in Windows-built releases such as DLSS5-Feeder).
extract_zip() {
    local zip_path="$1"
    local dest_dir="$2"
    mkdir -p "$dest_dir"

    if command -v 7z &>/dev/null; then
        # -y = assume Yes, -o = output dir (no space after -o)
        7z x -y -o"$dest_dir" "$zip_path" >/dev/null
        return $?
    fi

    # Fallback: unzip. Some builds warn about backslashes but still extract.
    # Redirect stderr so the backslash warning does not look like a hard error.
    if unzip -q -o "$zip_path" -d "$dest_dir" 2>/dev/null; then
        return 0
    fi

    # Last resort: try unzip even if it printed the backslash warning
    unzip -o "$zip_path" -d "$dest_dir" 2>&1 | grep -v "backslashes as path separators" || true
    # Check whether anything was actually extracted
    if [[ -z "$(find "$dest_dir" -type f | head -1)" ]]; then
        log_error "Failed to extract $zip_path"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Step 1 – ReShade (add-on build) → dxgi.dll
# ---------------------------------------------------------------------------
step_reshade() {
    log_step "1. ReShade (add-on support build)"

    if [[ -f "$MPV_DIR/dxgi.dll" && $FORCE -eq 0 ]]; then
        if [[ -f "$MPV_DIR/$RESHADE_MARKER" ]]; then
            log_ok "ReShade already present (managed by this script)"
            return 0
        else
            log_warn "dxgi.dll exists but was not placed by this script – skipping"
            return 0
        fi
    fi

    # Resolve latest Addon installer from reshade.me
    local html
    html=$(curl -fsSL "https://reshade.me") || {
        log_error "Cannot reach reshade.me"
        return 1
    }

    local version
    version=$(echo "$html" | grep -oP 'ReShade_Setup_\K[0-9.]+(?=_Addon\.exe)' | head -1)
    if [[ -z "$version" ]]; then
        log_error "Could not parse ReShade version from reshade.me"
        return 1
    fi
    log_info "Latest ReShade add-on version: $version"

    local setup_url="https://reshade.me/downloads/ReShade_Setup_${version}_Addon.exe"
    local setup_file="$CACHE_DIR/ReShade_Setup_${version}_Addon.exe"

    download "$setup_url" "$setup_file" "ReShade Setup $version"

    # Extract ReShade64.dll and rename it to dxgi.dll
    # 7z is the most reliable tool for PE + appended ZIP
    if ! command -v 7z &>/dev/null; then
        log_error "7z (p7zip) is required to extract the DLL from ReShade Setup.exe"
        log_error "Install it with: apt install p7zip-full   or   pacman -S p7zip"
        return 1
    fi

    log_info "Extracting ReShade64.dll → dxgi.dll ..."
    if 7z e -y -so "$setup_file" "ReShade64.dll" > "$MPV_DIR/dxgi.dll" 2>/dev/null; then
        echo "$version" > "$MPV_DIR/$RESHADE_MARKER"
        log_ok "ReShade $version installed as dxgi.dll"
    else
        log_error "Failed to extract ReShade64.dll from the Setup executable"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 2 – ReShade shader headers
# ---------------------------------------------------------------------------
step_headers() {
    log_step "2. ReShade shader headers"

    local shaders_dir="$MPV_DIR/reshade-shaders/Shaders"
    mkdir -p "$shaders_dir"

    local base="https://raw.githubusercontent.com/crosire/reshade-shaders/slim/Shaders"
    for h in ReShade.fxh ReShadeUI.fxh DrawText.fxh; do
        local dest="$shaders_dir/$h"
        if [[ -f "$dest" && $FORCE -eq 0 ]]; then
            continue
        fi
        download "$base/$h" "$dest" "$h"
    done
    log_ok "Shader headers installed"
}

# ---------------------------------------------------------------------------
# Step 3 – DLSS5-Feeder
# ---------------------------------------------------------------------------
step_feeder() {
    log_step "3. DLSS5-Feeder"

    # Recent releases put files under a versioned folder, e.g.:
    #   DLSS5-Feeder-0.15.1/reshade-shaders/Shaders/DLSS5_Feed.fx
    #   DLSS5-Feeder-0.15.1/dlss5-feed.addon64
    # Always extract the whole zip and use find — more reliable than
    # extract_member with wildcards (which previously produced empty files).
    local tag="1.17.0-beta.1"
    local zip_name="DLSS5-Feeder-${tag#v}.zip"
    local zip_url="https://github.com/jlrouzies-fr/DLSS5-Feeder/releases/download/${tag}/${zip_name}"
    local zip_file="$CACHE_DIR/${zip_name}"

    download "$zip_url" "$zip_file" "DLSS5-Feeder $tag"

    local tmp="$WORK_DIR/feeder"
    rm -rf "$tmp"
    extract_zip "$zip_file" "$tmp"

    # --- addon ---
    local addon
    addon=$(find "$tmp" -type f -name "dlss5-feed.addon64" | head -1)
    if [[ -z "$addon" || ! -s "$addon" ]]; then
        log_error "dlss5-feed.addon64 not found (or empty) inside $zip_name"
        return 1
    fi
    cp -f "$addon" "$MPV_DIR/dlss5-feed.addon64"
    log_ok "dlss5-feed.addon64 ($(wc -c < "$MPV_DIR/dlss5-feed.addon64") bytes)"

    # --- shader (critical: must not be empty) ---
    mkdir -p "$MPV_DIR/reshade-shaders/Shaders"
    local shader
    shader=$(find "$tmp" -type f -name "DLSS5_Feed.fx" | head -1)
    if [[ -z "$shader" || ! -s "$shader" ]]; then
        log_error "DLSS5_Feed.fx not found (or empty) inside $zip_name"
        return 1
    fi
    cp -f "$shader" "$MPV_DIR/reshade-shaders/Shaders/DLSS5_Feed.fx"
    local sz
    sz=$(wc -c < "$MPV_DIR/reshade-shaders/Shaders/DLSS5_Feed.fx")
    if [[ "$sz" -lt 1000 ]]; then
        log_error "DLSS5_Feed.fx is suspiciously small ($sz bytes) — extraction failed"
        return 1
    fi
    log_ok "DLSS5_Feed.fx ($sz bytes)"

    echo "$tag" > "$MPV_DIR/$FEEDER_MARKER"
    log_ok "DLSS5-Feeder $tag installed"
}

# ---------------------------------------------------------------------------
# Step 4 – LumeniteFX (motion-vector provider)
# ---------------------------------------------------------------------------
step_lumenite() {
    log_step "4. LumeniteFX (motion vectors)"

    local zip_url="https://codeload.github.com/umar-afzaal/LumeniteFX/zip/refs/heads/mainline"
    local zip_file="$CACHE_DIR/LumeniteFX-mainline.zip"

    download "$zip_url" "$zip_file" "LumeniteFX"

    local tmp="$WORK_DIR/lumenite"
    extract_zip "$zip_file" "$tmp"

    local root
    root=$(find "$tmp" -maxdepth 1 -type d -name "LumeniteFX-*" | head -1)

    mkdir -p "$MPV_DIR/reshade-shaders/Shaders/include"
    mkdir -p "$MPV_DIR/reshade-shaders/Textures"

    # Copy all lumenite shaders and the include folder
    cp -f "$root/Shaders/"*.fx "$MPV_DIR/reshade-shaders/Shaders/" 2>/dev/null || true
    cp -rf "$root/Shaders/include/"* "$MPV_DIR/reshade-shaders/Shaders/include/" 2>/dev/null || true

    # Blue-noise texture (optional but recommended)
    if [[ -f "$root/Textures/lumenite_bluenoise256.png" ]]; then
        cp -f "$root/Textures/lumenite_bluenoise256.png" "$MPV_DIR/reshade-shaders/Textures/"
    fi

    log_ok "LumeniteFX installed"
}

# ---------------------------------------------------------------------------
# Step 5 – renodx-dlss5.addon64 + NVIDIA runtimes
# ---------------------------------------------------------------------------
step_dlss5() {
    log_step "5. DLSS 5 add-on (renodx-dlss5) + NVIDIA runtimes"

    # ----- 5a. renodx-dlss5.addon64 (from RankFTW/rhi-repo) -----
    # Latest known good tag (update this when a newer one appears)
    local ver="6.5.3"
    local addon_tag="renodx-dlss5-${ver}"
    local addon_zip_name="renodx-dlss5_${ver}.zip"
    local addon_url="https://github.com/RankFTW/rhi-repo/releases/download/${addon_tag}/${addon_zip_name}"
    local addon_zip="$CACHE_DIR/${addon_zip_name}"

    if [[ -f "$MPV_DIR/renodx-dlss5.addon64" && $FORCE -eq 0 && -f "$MPV_DIR/$DLSS5_ADDON_MARKER" ]]; then
        log_ok "renodx-dlss5.addon64 already present"
    else
        download "$addon_url" "$addon_zip" "renodx-dlss5.addon64 ($addon_tag)"

        if ! extract_member "$addon_zip" "renodx-dlss5.addon64" "$MPV_DIR/renodx-dlss5.addon64"; then
            # Fallback: extract whole archive and search
            local tmp="$WORK_DIR/renodx"
            extract_zip "$addon_zip" "$tmp"
            find "$tmp" -name "renodx-dlss5.addon64" -exec cp {} "$MPV_DIR/" \;
        fi

        if [[ -f "$MPV_DIR/renodx-dlss5.addon64" ]]; then
            echo "$addon_tag" > "$MPV_DIR/$DLSS5_ADDON_MARKER"
            log_ok "renodx-dlss5.addon64 ($addon_tag) installed"
        else
            log_error "Failed to extract renodx-dlss5.addon64"
            return 1
        fi
    fi

    # ----- 5b. nvngx_dlssnr.dll (SF patched model for RTX 20/30) -----
    local nr_tag="dlssnr-310.8.SF-v2"
    local nr_url="https://github.com/RankFTW/rhi-repo/releases/download/${nr_tag}/nvngx_dlssnr_310.8.SF-v2.zip"
    local nr_zip="$CACHE_DIR/${nr_tag}.zip"

    if [[ -f "$MPV_DIR/nvngx_dlssnr.dll" && $FORCE -eq 0 && -f "$MPV_DIR/$DLSSNR_MARKER" ]]; then
        log_ok "nvngx_dlssnr.dll already present"
    else
        download "$nr_url" "$nr_zip" "nvngx_dlssnr.dll (310.8.SF-v2)"
        local tmp="$WORK_DIR/nr"
        extract_zip "$nr_zip" "$tmp"
        find "$tmp" -name "nvngx_dlssnr.dll" -exec cp {} "$MPV_DIR/" \;
        echo "$nr_tag" > "$MPV_DIR/$DLSSNR_MARKER"
        log_ok "nvngx_dlssnr.dll installed"
    fi

    # ----- 5c. nvngx_dlss.dll (required by Feeder NGX session) -----
    local dlss_tag="dlss-310.9.0"
    local dlss_url="https://github.com/RankFTW/rhi-repo/releases/download/${dlss_tag}/nvngx_dlss_310.9.0.zip"
    local dlss_zip="$CACHE_DIR/${dlss_tag}.zip"

    if [[ -f "$MPV_DIR/nvngx_dlss.dll" && $FORCE -eq 0 && -f "$MPV_DIR/$DLSS_MARKER" ]]; then
        log_ok "nvngx_dlss.dll already present"
    else
        download "$dlss_url" "$dlss_zip" "nvngx_dlss.dll (310.9.0)"
        local tmp="$WORK_DIR/dlss"
        extract_zip "$dlss_zip" "$tmp"
        find "$tmp" -name "nvngx_dlss.dll" -exec cp {} "$MPV_DIR/" \;
        echo "$dlss_tag" > "$MPV_DIR/$DLSS_MARKER"
        log_ok "nvngx_dlss.dll installed"
    fi
}

# ---------------------------------------------------------------------------
# Step 6 – Configuration files
# ---------------------------------------------------------------------------
step_config() {
    log_step "6. Writing ReShade configuration"

    cat > "$MPV_DIR/ReShade.ini" << 'EOF'
[GENERAL]
EffectSearchPaths=.\reshade-shaders\Shaders
TextureSearchPaths=.\reshade-shaders\Textures
PreprocessorDefinitions=DLSS5_MV_PROVIDER=3
PerformanceMode=0
ShowFPS=0
ShowClock=0

[INPUT]
KeyOverlay=36,0,0,0   ; Home

[ADDON]
AddonPath=
EOF

    cat > "$MPV_DIR/ReShadePreset.ini" << 'EOF'
Techniques=Lumenite_Kernel,DLSS5_Feed
TechniqueSorting=Lumenite_Kernel,DLSS5_Feed
EOF

    log_ok "ReShade.ini and ReShadePreset.ini written"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify() {
    log_step "Verifying installation"

    local missing=0
    local required=(
        "dxgi.dll"
        "dlss5-feed.addon64"
        "renodx-dlss5.addon64"
        "nvngx_dlssnr.dll"
        "nvngx_dlss.dll"
        "ReShade.ini"
        "reshade-shaders/Shaders/DLSS5_Feed.fx"
        "reshade-shaders/Shaders/ReShade.fxh"
    )

    for f in "${required[@]}"; do
        if [[ -f "$MPV_DIR/$f" ]]; then
            if [[ "$f" == *DLSS5_Feed.fx && ! -s "$MPV_DIR/$f" ]]; then
                log_error "Empty file: $f (extraction failed earlier)"
                missing=$((missing + 1))
            else
                log_ok "$f"
            fi
        else
            log_error "Missing: $f"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        log_ok "All critical files are present"
        return 0
    else
        log_error "$missing file(s) missing"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "======================================================================"
    echo "  DLSS5 Installation Script for MPV / DX games"
    echo "======================================================================"
    echo "Target directory : $MPV_DIR"
    echo "Cache directory  : $CACHE_DIR"
    echo "Force overwrite  : $FORCE"
    echo

    # Dependency checks
    for cmd in curl unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    if ! command -v 7z &>/dev/null; then
        log_warn "7z not found – ReShade extraction will fail"
        log_warn "Install with:  apt install p7zip-full  /  pacman -S p7zip  /  brew install p7zip"
    fi

    # Directory checks
    if [[ ! -d "$MPV_DIR" ]]; then
        log_error "Directory does not exist: $MPV_DIR"
        exit 1
    fi
    if ! touch "$MPV_DIR/.write_test" 2>/dev/null; then
        log_error "No write permission in $MPV_DIR"
        exit 1
    fi
    rm -f "$MPV_DIR/.write_test"

    # Run installation steps
    step_reshade
    step_headers
    step_feeder
    step_lumenite
    step_dlss5
    step_config
    verify

    echo
    echo "======================================================================"
    echo "  Installation finished"
    echo "======================================================================"
    echo
    echo "Next steps:"
    echo "  1. Launch MPV → press Home to open ReShade"
    echo "  2. Add-ons tab → enable \"DLSS 5 Neural Rendering\""
    echo "  3. Effects list: Lumenite_Kernel must be ABOVE DLSS5_Feed"
    echo "  4. Check dlss5-feed.log for 'feature ready … DLAA'"
    echo
    echo "Hotkeys (default):"
    echo "  Home  – toggle ReShade overlay"
    echo "  F6    – toggle Neural Rendering (add-on hotkey)"
    echo "  F5    – save screenshot (add-on hotkey)"
    echo
}

main "$@"
