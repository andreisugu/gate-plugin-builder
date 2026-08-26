#!/usr/bin/env bash
# =============================================================================
#                   Gate Proxy + Extension Builder
# =============================================================================
# A production-ready, zero-configuration build engine for compiling
# Minekube Gate Minecraft Proxy with local and remote Go extensions.
#
# Supported Environments:
#   - Local development (Linux, macOS, Windows/WSL, NixOS)
#   - Pelican / Pterodactyl Panels & Yolks Docker Images
#   - CI/CD Pipelines (GitHub Actions, GitLab CI, Dockerfiles)
#
# GitHub: https://github.com/minekube/gate-plugin-template
# License: Apache-2.0
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Toolchain Auto-Detection & Container Provisioning
# -----------------------------------------------------------------------------
# Auto-install Go & dependencies if running inside a container as root (e.g. Pelican installer)
if ! command -v go >/dev/null 2>&1; then
    if [ -w / ] && command -v apk >/dev/null 2>&1; then
        echo "📦 Installing Go compiler and dependencies via apk..."
        apk add --no-cache go git bash ca-certificates
    elif [ -w / ] && command -v apt-get >/dev/null 2>&1; then
        echo "📦 Installing Go compiler and dependencies via apt-get..."
        apt-get update -qq && apt-get install -y -qq --no-install-recommends golang-go git ca-certificates
    elif command -v nix >/dev/null 2>&1 && [ "${NIX_WRAPPED:-0}" != "1" ]; then
        export NIX_WRAPPED=1
        exec nix shell nixpkgs#go nixpkgs#patchelf --command "$0" "$@"
    else
        echo "❌ Error: 'go' is required to compile Gate." >&2
        echo "Please install Go (1.20+) from: https://go.dev/dl/" >&2
        exit 1
    fi
fi

# Ensure reliable Go module downloads in all environments
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"

# -----------------------------------------------------------------------------
# 2. Colors & Terminal Styling
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
    GREEN=$'\033[1;32m'
    BLUE=$'\033[1;34m'
    CYAN=$'\033[1;36m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    MAGENTA=$'\033[1;35m'
    DIM=$'\033[2m'
else
    BOLD=""
    RESET=""
    GREEN=""
    BLUE=""
    CYAN=""
    YELLOW=""
    RED=""
    MAGENTA=""
    DIM=""
fi

# -----------------------------------------------------------------------------
# 3. Default Configuration & CLI Arguments
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Respect Pelican's SERVER_BINARY environment variable
OUTPUT_BINARY="${OUTPUT_BINARY:-${SERVER_BINARY:-gate}}"
GATE_VERSION="${GATE_VERSION:-latest}"
TARGET_OS="${TARGET_OS:-$(go env GOOS 2>/dev/null || echo "linux")}"
TARGET_ARCH="${TARGET_ARCH:-$(go env GOARCH 2>/dev/null || echo "amd64")}"
PLUGIN_FILE="${PLUGIN_FILE:-}"
ENABLE_DEBUG=false
DRY_RUN=false
SKIP_PATCHELF=false
DO_CLEAN=false

# Plugin sources list (populated via CLI, file, env var, or auto-discovery)
RAW_PLUGINS=()

show_help() {
    cat << EOF
${BOLD}Gate Proxy Extension Builder${RESET}

${BOLD}USAGE:${RESET}
    ./build.sh [OPTIONS]

${BOLD}OPTIONS:${RESET}
    ${CYAN}-p, --plugins <list>${RESET}     Comma or space-separated list of plugins.
                             Supports local paths (e.g. '../gate-discord4gate', './plugins/myplugin')
                             and remote Go modules/Git URLs (e.g. 'github.com/user/myplugin', 'https://github.com/...').
    ${CYAN}-f, --file <path>${RESET}        Path to a text file containing plugin list (default: 'plugins.txt' if present).
    ${CYAN}-o, --output <path>${RESET}      Output binary name or path (default: './gate' or '\$SERVER_BINARY').
    ${CYAN}-v, --version <tag>${RESET}       Gate upstream version or tag (default: 'latest').
    ${CYAN}-t, --target <os/arch>${RESET}   Target platform (e.g. 'linux/amd64', 'linux/arm64', 'windows/amd64').
    ${CYAN}-d, --debug${RESET}               Enable debug build (preserves symbol tables and line numbers).
    ${CYAN}-c, --clean${RESET}               Clean build artifacts, temporary files, and go cache.
    ${CYAN}--no-patch${RESET}                Skip ELF interpreter patching on Linux.
    ${CYAN}--dry-run${RESET}                 Generate 'gate.go' and 'go.mod' without compiling.
    ${CYAN}-h, --help${RESET}                Show this help message.

${BOLD}ENVIRONMENT VARIABLES:${RESET}
    ${YELLOW}GATE_PLUGINS${RESET}             Comma or space-separated list of plugins (Pelican/Docker compatible).
    ${YELLOW}PLUGIN_FILE${RESET}              Path to plugins text file (e.g. 'plugins.txt').
    ${YELLOW}SERVER_BINARY${RESET}            Pelican server executable name (default: 'gate').
    ${YELLOW}GATE_VERSION${RESET}             Upstream Gate version (default: 'latest').
    ${YELLOW}OUTPUT_BINARY${RESET}            Target output binary name.
    ${YELLOW}TARGET_OS${RESET}                Target OS (e.g. 'linux', 'darwin', 'windows').
    ${YELLOW}TARGET_ARCH${RESET}              Target Architecture (e.g. 'amd64', 'arm64').

${BOLD}EXAMPLES:${RESET}
    ${DIM}# Read from 'plugins.txt' or auto-discover local plugins:${RESET}
    ./build.sh

    ${DIM}# Build from a custom plugin manifest file:${RESET}
    ./build.sh -f custom-plugins.txt

    ${DIM}# Build with specific local and remote plugins:${RESET}
    ./build.sh -p "../gate-discord4gate, https://github.com/andreisugu/gate-bettertab.git"

    ${DIM}# Cross-compile for Linux ARM64 (e.g. Raspberry Pi / Oracle Ampere):${RESET}
    ./build.sh --target linux/arm64 -o gate-arm64

    ${DIM}# Build with a pinned Gate version:${RESET}
    ./build.sh -v v0.71.3

EOF
    exit 0
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -p|--plugins)
            IFS=',' read -r -a parsed_p <<< "$2"
            for item in "${parsed_p[@]}"; do
                trimmed="$(echo "$item" | xargs)"
                if [ -n "$trimmed" ]; then
                    RAW_PLUGINS+=("$trimmed")
                fi
            done
            shift 2
            ;;
        -f|--file)
            PLUGIN_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_BINARY="$2"
            shift 2
            ;;
        -v|--version)
            GATE_VERSION="$2"
            shift 2
            ;;
        -t|--target)
            IFS='/' read -r TARGET_OS TARGET_ARCH <<< "$2"
            shift 2
            ;;
        -d|--debug)
            ENABLE_DEBUG=true
            shift
            ;;
        -c|--clean)
            DO_CLEAN=true
            shift
            ;;
        --no-patch)
            SKIP_PATCHELF=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "${RED}❌ Unknown option:${RESET} $1" >&2
            echo "Run ${CYAN}./build.sh --help${RESET} for usage information." >&2
            exit 1
            ;;
    esac
done

# Adjust binary extension for Windows targets
if [ "$TARGET_OS" = "windows" ] && [[ "$OUTPUT_BINARY" != *.exe ]]; then
    OUTPUT_BINARY="${OUTPUT_BINARY}.exe"
fi

# -----------------------------------------------------------------------------
# 4. Clean Task
# -----------------------------------------------------------------------------
if [ "$DO_CLEAN" = true ]; then
    echo "${YELLOW}🧹 Cleaning build artifacts and cache...${RESET}"
    rm -f "$OUTPUT_BINARY" "${OUTPUT_BINARY}.exe" gate.go gate
    rm -f /tmp/gate-* 2>/dev/null || true
    if command -v go >/dev/null 2>&1; then
        go clean -cache -modcache 2>/dev/null || true
    fi
    echo "${GREEN}✅ Clean completed.${RESET}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 5. Banner & Environment Diagnostics
# -----------------------------------------------------------------------------
echo "${BLUE}============================================================${RESET}"
echo "${BOLD}  🔨 Gate Proxy + Extension Builder${RESET}"
echo "${BLUE}============================================================${RESET}"

GO_VER_STR="$(go version)"
echo "${DIM}📦 Toolchain:${RESET}   $GO_VER_STR"
echo "${DIM}🎯 Target:${RESET}      ${TARGET_OS}/${TARGET_ARCH}"
echo "${DIM}🌐 Gate Core:${RESET}   ${GATE_VERSION}"
echo "${DIM}📁 Output:${RESET}      ${OUTPUT_BINARY}"

# Ensure root go.mod exists
if [ ! -f "go.mod" ]; then
    echo "${YELLOW}⚠️  go.mod missing in root. Initializing default module...${RESET}"
    go mod init gate-custom
fi

ROOT_MOD=$(head -n 1 "$SCRIPT_DIR/go.mod" | awk '{print $2}')

parse_plugin_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "${RED}❌ Error: Plugin file not found:${RESET} $file" >&2
        exit 1
    fi
    echo "${CYAN}📄 Loading plugins from manifest:${RESET} $(basename "$file")"
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading/trailing whitespace
        line="$(echo "$line" | xargs)"
        # Skip empty lines or whole-line comments (# or //)
        if [ -z "$line" ] || [[ "$line" =~ ^# ]] || [[ "$line" =~ ^\/\/ ]]; then
            continue
        fi
        # Strip inline '#' comments
        line="${line%%#*}"
        # Strip inline ' //' comments
        if [[ "$line" =~ ^(.*)[[:space:]]+\/\/(.*)$ ]]; then
            line="${BASH_REMATCH[1]}"
        fi
        line="$(echo "$line" | xargs)"
        if [ -n "$line" ]; then
            RAW_PLUGINS+=("$line")
        fi
    done < "$file"
}

# -----------------------------------------------------------------------------
# 6. Collect & Auto-Discover Plugins
# -----------------------------------------------------------------------------
# 1. From explicit --file flag
if [ -n "$PLUGIN_FILE" ]; then
    parse_plugin_file "$PLUGIN_FILE"
fi

# 2. From GATE_PLUGINS environment variable (Pelican panel / Docker)
if [ ${#RAW_PLUGINS[@]} -eq 0 ] && [ -n "${GATE_PLUGINS:-}" ]; then
    echo "${CYAN}📋 Loading plugins from GATE_PLUGINS environment variable...${RESET}"
    IFS=',' read -r -a env_plugins <<< "$GATE_PLUGINS"
    for item in "${env_plugins[@]}"; do
        trimmed="$(echo "$item" | xargs)"
        if [ -n "$trimmed" ]; then
            RAW_PLUGINS+=("$trimmed")
        fi
    done
fi

# 3. From default 'plugins.txt' in project directory if present
if [ ${#RAW_PLUGINS[@]} -eq 0 ] && [ -f "$SCRIPT_DIR/plugins.txt" ]; then
    parse_plugin_file "$SCRIPT_DIR/plugins.txt"
fi

# 4. If still empty, perform auto-discovery of local extensions
if [ ${#RAW_PLUGINS[@]} -eq 0 ]; then
    echo "${CYAN}🔍 Auto-discovering local extension folders...${RESET}"
    
    # Discover adjacent directories matching ../gate-*
    for adj in ../gate-*; do
        if [ -d "$adj" ]; then
            abs_adj="$(cd "$adj" && pwd)"
            if [ "$abs_adj" != "$SCRIPT_DIR" ]; then
                RAW_PLUGINS+=("$adj")
            fi
        fi
    done

    # Discover subdirectories inside ./plugins/
    if [ -d "plugins" ]; then
        for plug in plugins/*/; do
            if [ -d "$plug" ]; then
                RAW_PLUGINS+=("${plug%/}")
            fi
        done
    fi
fi

# -----------------------------------------------------------------------------
# 7. Parse and Resolve Extensions (with Deduplication)
# -----------------------------------------------------------------------------
IMPORTS=()
REGISTRATIONS=()
REPLACES=()
REMOTE_FETCHES=()
SUMMARY_ENTRIES=()
SEEN_MODULES=()
SEEN_PATHS=()

INDEX=0

is_seen() {
    local mod="$1"
    local path="${2:-}"
    for m in "${SEEN_MODULES[@]}"; do
        if [ -n "$mod" ] && [ "$m" = "$mod" ]; then
            return 0
        fi
    done
    if [ -n "$path" ]; then
        for p in "${SEEN_PATHS[@]}"; do
            if [ "$p" = "$path" ]; then
                return 0
            fi
        done
    fi
    return 1
}

normalize_git_url() {
    local str="$1"
    str="$(echo "$str" | xargs)"
    str="${str#https://}"
    str="${str#http://}"
    str="${str#git://}"
    if [[ "$str" =~ ^git@([^:]+):(.+)$ ]]; then
        str="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
    # Strip .git before @version or at the end
    if [[ "$str" == *"@"* ]]; then
        local mod="${str%@*}"
        local ver="${str#*@}"
        mod="${mod%.git}"
        str="${mod}@${ver}"
    else
        str="${str%.git}"
    fi
    echo "$str"
}

for RAW_ITEM in "${RAW_PLUGINS[@]}"; do
    ITEM="$(echo "$RAW_ITEM" | xargs)"
    if [ -z "$ITEM" ]; then
        continue
    fi

    # 1. Check if ITEM is a local directory
    if [ -d "$ITEM" ] || [ -d "$SCRIPT_DIR/$ITEM" ]; then
        if [ -d "$ITEM" ]; then
            ABS_PATH="$(cd "$ITEM" && pwd)"
        else
            ABS_PATH="$(cd "$SCRIPT_DIR/$ITEM" && pwd)"
        fi

        if [ "$ABS_PATH" = "$SCRIPT_DIR" ]; then
            continue
        fi

        # Determine Go Module path
        if [ -f "$ABS_PATH/go.mod" ]; then
            MOD_PATH=$(head -n 1 "$ABS_PATH/go.mod" | awk '{print $2}')
        else
            if [[ "$ABS_PATH" == "$SCRIPT_DIR/"* ]]; then
                REL_PATH="${ABS_PATH#$SCRIPT_DIR/}"
            else
                REL_PATH="$(basename "$ABS_PATH")"
            fi
            MOD_PATH="${ROOT_MOD}/${REL_PATH}"
        fi

        # Check for duplicates
        if is_seen "$MOD_PATH" "$ABS_PATH"; then
            continue
        fi
        SEEN_MODULES+=("$MOD_PATH")
        SEEN_PATHS+=("$ABS_PATH")

        REPLACES+=("${MOD_PATH}=${ABS_PATH}")

        INDEX=$((INDEX + 1))
        ALIAS="ext_${INDEX}"
        NAME="$(basename "$ABS_PATH")"

        # Find exported plugin symbol (default: Plugin)
        PLUGIN_VAR="Plugin"
        DETECTED_VAR=$(grep -h -E -o 'var [A-Z][a-zA-Z0-9_]* = proxy\.Plugin' "$ABS_PATH"/*.go 2>/dev/null | head -n 1 | awk '{print $2}' || true)
        if [ -n "$DETECTED_VAR" ]; then
            PLUGIN_VAR="$DETECTED_VAR"
        fi

        IMPORTS+=("${ALIAS} \"${MOD_PATH}\"")
        REGISTRATIONS+=("${ALIAS}.${PLUGIN_VAR}")
        SUMMARY_ENTRIES+=("  ${GREEN}➕ [Local]${RESET}  ${BOLD}${NAME}${RESET}\n      ${DIM}Path:${RESET}   ${ABS_PATH}\n      ${DIM}Module:${RESET} ${MOD_PATH}\n      ${DIM}Symbol:${RESET} ${PLUGIN_VAR}")

    # 2. Check if ITEM is a Remote Go Module or Git URL (https://..., git@..., github.com/...)
    else
        NORMALIZED="$(normalize_git_url "$ITEM")"
        PKG_MOD="$NORMALIZED"
        PKG_VER="latest"

        if [[ "$NORMALIZED" == *"@"* ]]; then
            PKG_MOD="${NORMALIZED%@*}"
            PKG_VER="${NORMALIZED#*@}"
        fi

        if [[ "$PKG_MOD" =~ ^[a-zA-Z0-9.\_-]+\.[a-zA-Z]{2,}/.+ ]]; then
            # Check for duplicates
            if is_seen "$PKG_MOD" ""; then
                continue
            fi
            SEEN_MODULES+=("$PKG_MOD")

            INDEX=$((INDEX + 1))
            ALIAS="ext_${INDEX}"
            MOD_PATH="$PKG_MOD"
            FETCH_TARGET="${PKG_MOD}@${PKG_VER}"
            NAME="$(basename "$PKG_MOD")"
            PLUGIN_VAR="Plugin"

            REMOTE_FETCHES+=("$FETCH_TARGET")
            IMPORTS+=("${ALIAS} \"${MOD_PATH}\"")
            REGISTRATIONS+=("${ALIAS}.${PLUGIN_VAR}")
            SUMMARY_ENTRIES+=("  ${CYAN}🌐 [Remote]${RESET} ${BOLD}${NAME}${RESET} ${DIM}(${PKG_VER})${RESET}\n      ${DIM}Module:${RESET} ${MOD_PATH}\n      ${DIM}Source:${RESET} ${ITEM}\n      ${DIM}Symbol:${RESET} ${PLUGIN_VAR}")
        else
            echo "${YELLOW}⚠️  Warning: Skipping unresolvable plugin source:${RESET} $ITEM"
        fi
    fi
done

# Print Summary of Extensions
if [ ${#SUMMARY_ENTRIES[@]} -eq 0 ]; then
    echo "${YELLOW}ℹ️  No external extensions specified. Building vanilla Gate proxy...${RESET}"
else
    echo "${BOLD}📋 Extensions to bundle (${INDEX} total):${RESET}"
    for entry in "${SUMMARY_ENTRIES[@]}"; do
        echo -e "$entry"
    done
fi

# -----------------------------------------------------------------------------
# 8. Generate gate.go Entrypoint
# -----------------------------------------------------------------------------
echo ""
echo "${CYAN}📝 Generating entrypoint (gate.go)...${RESET}"

cat << 'EOF' > gate.go
// Code generated by build.sh. DO NOT EDIT.
package main

import (
	"go.minekube.com/gate/cmd/gate"
	"go.minekube.com/gate/pkg/edition/java/proxy"
EOF

# Inject imports
for imp in "${IMPORTS[@]}"; do
    echo "	$imp" >> gate.go
done

cat << 'EOF' >> gate.go
)

func main() {
	proxy.Plugins = append(proxy.Plugins,
EOF

# Inject plugin registrations
for reg in "${REGISTRATIONS[@]}"; do
    echo "		$reg," >> gate.go
done

cat << 'EOF' >> gate.go
	)

	gate.Execute()
}
EOF

# -----------------------------------------------------------------------------
# 9. Synchronize Dependencies (go.mod / go get)
# -----------------------------------------------------------------------------
echo "${CYAN}🔗 Configuring module replacements and dependencies...${RESET}"

# Apply local replace directives
for rep in "${REPLACES[@]}"; do
    go mod edit -replace "$rep"
done

# Fetch Gate upstream dependency
echo "${CYAN}🌐 Fetching Gate core (go.minekube.com/gate@${GATE_VERSION})...${RESET}"
go get "go.minekube.com/gate@${GATE_VERSION}"

# Fetch any remote extensions
for target in "${REMOTE_FETCHES[@]}"; do
    echo "${CYAN}⬇️  Fetching remote plugin ${target}...${RESET}"
    go get "$target" || {
        base_mod="${target%@*}"
        echo "${YELLOW}⚠️  Retrying with latest version: ${base_mod}@latest...${RESET}"
        go get "${base_mod}@latest" || go get "${base_mod}"
    }
done

echo "${CYAN}🧹 Running go mod tidy...${RESET}"
go mod tidy

# If dry run, stop here
if [ "$DRY_RUN" = true ]; then
    echo "${GREEN}✨ Dry run completed successfully! (gate.go and go.mod generated)${RESET}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 10. Compile Gate Binary
# -----------------------------------------------------------------------------
LDFLAGS="-s -w"
if [ "$ENABLE_DEBUG" = true ]; then
    LDFLAGS=""
    echo "${MAGENTA}⚡ Compiling in DEBUG mode (GOOS=${TARGET_OS} GOARCH=${TARGET_ARCH})...${RESET}"
else
    echo "${MAGENTA}⚡ Compiling optimized static binary (GOOS=${TARGET_OS} GOARCH=${TARGET_ARCH})...${RESET}"
fi

BUILD_DURATION=""
BUILD_START_NANO=$(date +%s%N 2>/dev/null || true)
BUILD_START_SEC=$(date +%s)

CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" go build \
    -trimpath \
    ${LDFLAGS:+-ldflags="$LDFLAGS"} \
    -o "$OUTPUT_BINARY" .

if [[ "$BUILD_START_NANO" =~ ^[0-9]+$ ]]; then
    BUILD_END_NANO=$(date +%s%N 2>/dev/null || true)
    if [[ "$BUILD_END_NANO" =~ ^[0-9]+$ ]] && [ "$BUILD_END_NANO" -gt "$BUILD_START_NANO" ]; then
        DIFF=$(( (BUILD_END_NANO - BUILD_START_NANO) / 1000000 ))
        BUILD_DURATION=" in $(awk "BEGIN {printf \"%.3f\", $DIFF/1000}")s"
    fi
else
    BUILD_END_SEC=$(date +%s)
    DIFF=$(( BUILD_END_SEC - BUILD_START_SEC ))
    BUILD_DURATION=" in ${DIFF}s"
fi

# -----------------------------------------------------------------------------
# 11. ELF Interpreter Normalization (for Linux x86_64)
# -----------------------------------------------------------------------------
if [ "$TARGET_OS" = "linux" ] && [ "$TARGET_ARCH" = "amd64" ] && [ "$SKIP_PATCHELF" = false ]; then
    if command -v patchelf >/dev/null 2>&1; then
        patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$OUTPUT_BINARY" 2>/dev/null || true
    elif command -v nix >/dev/null 2>&1; then
        nix shell nixpkgs#patchelf --command patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$OUTPUT_BINARY" 2>/dev/null || true
    fi
fi

chmod +x "$OUTPUT_BINARY"

BINARY_SIZE=$(ls -lh "$OUTPUT_BINARY" | awk '{print $5}')

# -----------------------------------------------------------------------------
# 12. Build Complete Banner
# -----------------------------------------------------------------------------
echo ""
echo "${GREEN}============================================================${RESET}"
echo "${GREEN}  🎉 Build Successful!${BUILD_DURATION}${RESET}"
echo "${GREEN}============================================================${RESET}"
echo "  ${BOLD}Artifact:${RESET}   $SCRIPT_DIR/$OUTPUT_BINARY"
echo "  ${BOLD}Size:${RESET}       $BINARY_SIZE"
echo "  ${BOLD}Target:${RESET}     ${TARGET_OS}/${TARGET_ARCH} (Static, CGO=0)"
echo "  ${BOLD}Plugins:${RESET}    ${INDEX} extensions active"
echo "${GREEN}============================================================${RESET}"
echo ""
echo "▶️  ${BOLD}Run Gate:${RESET}  ./${OUTPUT_BINARY}"
echo ""
