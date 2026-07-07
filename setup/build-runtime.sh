#!/bin/bash
# build-runtime.sh вЂ” Generated runtime architecture (WP-273 Р­С‚Р°Рї 2 Р¤18)
#
# Idempotent rebuild $WORKSPACE_DIR/.iwe-runtime/ from FMT-exocortex-template + .exocortex.env.
# РђРЅР°Р»РѕРі Nix derivation: РѕРґРЅРё Рё С‚Рµ Р¶Рµ РІС…РѕРґС‹ в†’ identical output.
#
# Source-of-truth: РЅР°СЃС‚РѕСЏС‰РёР№ FMT (immutable, regenerable).
# Output: $WORKSPACE_DIR/.iwe-runtime/ (regenerable, РЅРµ РІ git).
# Trigger: setup.sh, update.sh, СЂСѓС‡РЅРѕР№ Р·Р°РїСѓСЃРє.
#
# Usage:
#   bash build-runtime.sh                   # rebuild + write
#   bash build-runtime.sh --dry-run         # РїРѕРєР°Р·Р°С‚СЊ С‡С‚Рѕ Р±СѓРґРµС‚ СЃРѕР·РґР°РЅРѕ, Р±РµР· Р·Р°РїРёСЃРё
#   bash build-runtime.sh --diff            # diff РјРµР¶РґСѓ С‚РµРєСѓС‰РёРј runtime Рё С‚РµРј, С‡С‚Рѕ Р±С‹Р» Р±С‹ СЃРѕР·РґР°РЅ
#   bash build-runtime.sh --workspace PATH  # СЏРІРЅРѕ СѓРєР°Р·Р°С‚СЊ workspace (default: parent of FMT)
#   bash build-runtime.sh --env-file PATH   # СЏРІРЅРѕ СѓРєР°Р·Р°С‚СЊ .exocortex.env
#   bash build-runtime.sh --quiet           # РјРёРЅРёРјР°Р»СЊРЅС‹Р№ РІС‹РІРѕРґ (РґР»СЏ setup/update.sh)
#
# Exit codes:
#   0 вЂ” СѓСЃРїРµС… (РёР»Рё dry-run/diff Р±РµР· Р±Р»РѕРєРµСЂРѕРІ)
#   1 вЂ” РЅРµРєРѕСЂСЂРµРєС‚РЅС‹Рµ Р°СЂРіСѓРјРµРЅС‚С‹
#   2 вЂ” РѕС‚СЃСѓС‚СЃС‚РІСѓРµС‚ .exocortex.env
#   3 вЂ” overlay-СЂРµРµСЃС‚СЂ РЅРµ РЅР°Р№РґРµРЅ
#   4 вЂ” РѕС‚СЃСѓС‚СЃС‚РІСѓСЋС‚ source-С„Р°Р№Р»С‹ РёР· СЂРµРµСЃС‚СЂР°
#   5 вЂ” drift detected (С‚РѕР»СЊРєРѕ РІ --diff СЂРµР¶РёРјРµ РїСЂРё РЅР°Р№РґРµРЅРЅС‹С… СЂР°СЃС…РѕР¶РґРµРЅРёСЏС…)
#
# WP-273 Р­С‚Р°Рї 2 Р¤18. ArchGate v2 в†’ F (Generated runtime).

set -eu

# === Cross-platform sed -i ===
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# === Cross-platform hash ===
hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

hash_dir() {
    local dir="$1"
    [ -d "$dir" ] || { echo "EMPTY"; return; }
    if command -v shasum >/dev/null 2>&1; then
        find "$dir" -type f -not -name '.build-hash' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
    else
        find "$dir" -type f -not -name '.build-hash' | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
    fi
}

# === Detect directories ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"  # FMT-exocortex-template/
DEFAULT_WORKSPACE="$(dirname "$TEMPLATE_DIR")"  # parent of FMT

WORKSPACE_DIR=""
ENV_FILE=""
DRY_RUN=false
DIFF_MODE=false
QUIET=false

# === Parse arguments ===
while [ $# -gt 0 ]; do
    case "$1" in
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --diff)
            DIFF_MODE=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --help|-h)
            grep '^#' "$0" | head -28
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: bash build-runtime.sh [--dry-run|--diff] [--workspace PATH] [--env-file PATH] [--quiet]" >&2
            exit 1
            ;;
    esac
done

# === Resolve workspace + env-file ===
WORKSPACE_DIR="${WORKSPACE_DIR:-$DEFAULT_WORKSPACE}"
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

if [ -z "$ENV_FILE" ]; then
    # РџРѕРёСЃРє .exocortex.env: workspace в†’ template (РґР»СЏ РјРёРіСЂР°С†РёРё СЃ СЃС‚Р°СЂРѕР№ СЂР°СЃРєР»Р°РґРєРё)
    if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
        ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
    elif [ -f "$TEMPLATE_DIR/.exocortex.env" ]; then
        ENV_FILE="$TEMPLATE_DIR/.exocortex.env"
        $QUIET || echo "  вљ  .exocortex.env РЅР°Р№РґРµРЅ РІ FMT (legacy location). Р‘СѓРґРµС‚ РјРёРіСЂРёСЂРѕРІР°РЅ РІ \$WORKSPACE_DIR/ РїСЂРё СЃР»РµРґСѓСЋС‰РµРј setup."
    fi
fi

if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .exocortex.env РЅРµ РЅР°Р№РґРµРЅ. РСЃРєР°Р»:" >&2
    echo "  - $WORKSPACE_DIR/.exocortex.env" >&2
    echo "  - $TEMPLATE_DIR/.exocortex.env" >&2
    echo "Р—Р°РїСѓСЃС‚РёС‚Рµ setup.sh РґР»СЏ РїРµСЂРІРёС‡РЅРѕР№ РєРѕРЅС„РёРіСѓСЂР°С†РёРё." >&2
    exit 2
fi

OVERLAY_FILE="$TEMPLATE_DIR/.claude/runtime-overlay.yaml"
if [ ! -f "$OVERLAY_FILE" ]; then
    echo "ERROR: Overlay-СЂРµРµСЃС‚СЂ РЅРµ РЅР°Р№РґРµРЅ: $OVERLAY_FILE" >&2
    exit 3
fi

RUNTIME_DIR="$WORKSPACE_DIR/.iwe-runtime"

if ! $QUIET; then
    echo "=== build-runtime ==="
    echo "  Template: $TEMPLATE_DIR"
    echo "  Workspace: $WORKSPACE_DIR"
    echo "  Env file: $ENV_FILE"
    echo "  Runtime: $RUNTIME_DIR"
    [ "$DRY_RUN" = true ] && echo "  Mode: DRY-RUN (no writes)"
    [ "$DIFF_MODE" = true ] && echo "  Mode: DIFF (compare existing vs new)"
    echo ""
fi

# === Load .exocortex.env ===
# Safe parse: С‚РѕР»СЊРєРѕ KEY=VALUE, РЅРёРєР°РєРѕРіРѕ eval/source.
# Bash 3.2-compatible: РёСЃРїРѕР»СЊР·СѓРµРј С„СѓРЅРєС†РёСЋ env_get РІРјРµСЃС‚Рѕ associative array.
env_get() {
    grep "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# === Parse overlay-СЂРµРµСЃС‚СЂ ===
# РњРёРЅРёРјР°Р»СЊРЅС‹Р№ YAML-РїР°СЂСЃРµСЂ: С‡РёС‚Р°РµС‚ СЃРїРёСЃРєРё substituted/copied_to_workspace.
# РћР¶РёРґР°РµРјС‹Р№ С„РѕСЂРјР°С‚: РєР»СЋС‡ РІ РЅР°С‡Р°Р»Рµ СЃС‚СЂРѕРєРё + РґРІРѕРµС‚РѕС‡РёРµ, РґР°Р»РµРµ `  - path` РґР»СЏ РєР°Р¶РґРѕРіРѕ С„Р°Р№Р»Р°.
parse_list() {
    local section="$1"
    awk -v sect="$section" '
        $0 ~ "^"sect":" { in_section=1; next }
        in_section && /^[a-z_]+:/ { in_section=0 }
        in_section && /^[[:space:]]+-[[:space:]]/ {
            sub(/^[[:space:]]+-[[:space:]]+/, "")
            sub(/[[:space:]]*#.*/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
        }
    ' "$OVERLAY_FILE"
}

# Bash 3.2-compatible array population (mapfile = bash 4+).
SUBSTITUTED_FILES=()
while IFS= read -r line; do SUBSTITUTED_FILES+=("$line"); done < <(parse_list "substituted")
COPIED_FILES=()
while IFS= read -r line; do COPIED_FILES+=("$line"); done < <(parse_list "copied_to_workspace")
PLACEHOLDERS=()
while IFS= read -r line; do PLACEHOLDERS+=("$line"); done < <(parse_list "placeholders")

if [ "${#SUBSTITUTED_FILES[@]}" -eq 0 ] && [ "${#COPIED_FILES[@]}" -eq 0 ]; then
    echo "ERROR: Overlay-СЂРµРµСЃС‚СЂ РїСѓСЃС‚ РёР»Рё РїРѕРІСЂРµР¶РґС‘РЅ: $OVERLAY_FILE" >&2
    exit 3
fi

# === Verify source files exist in FMT ===
MISSING=()
for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
    [ -f "$TEMPLATE_DIR/$f" ] || MISSING+=("$f")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "ERROR: Р¤Р°Р№Р»С‹ РёР· overlay-СЂРµРµСЃС‚СЂР° РѕС‚СЃСѓС‚СЃС‚РІСѓСЋС‚ РІ FMT:" >&2
    printf '  - %s\n' "${MISSING[@]}" >&2
    echo "Р’РѕР·РјРѕР¶РЅРѕ: СѓСЃС‚Р°СЂРµРІС€РёР№ runtime-overlay.yaml РёР»Рё РЅРµРїРѕР»РЅС‹Р№ clone." >&2
    exit 4
fi

# === Build runtime in temp directory (atomic swap on success) ===
if BUILD_DIR=$(mktemp -d 2>/dev/null); then
    :
else
    BUILD_DIR="/tmp/iwe-build-$$"
    mkdir -p "$BUILD_DIR"
fi
trap "rm -rf '$BUILD_DIR'" EXIT

# Hash inputs (FMT files + .exocortex.env) for build-stamp
INPUT_HASH=$(
    {
        for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
            hash_file "$TEMPLATE_DIR/$f"
            echo "$f"
        done
        hash_file "$ENV_FILE"
        hash_file "$OVERLAY_FILE"
    } | hash_file /dev/stdin 2>/dev/null || \
    {
        for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
            hash_file "$TEMPLATE_DIR/$f"
            echo "$f"
        done
        hash_file "$ENV_FILE"
        hash_file "$OVERLAY_FILE"
    } | (command -v shasum >/dev/null && shasum -a 256 || sha256sum) | cut -d' ' -f1
)

FMT_VERSION=$(grep -m1 '^## \[' "$TEMPLATE_DIR/CHANGELOG.md" | sed 's/.*\[\(.*\)\].*/\1/')

# === Apply substitutions ===
build_substituted_file() {
    local rel="$1"
    local src="$TEMPLATE_DIR/$rel"
    local dst="$BUILD_DIR/runtime/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"

    # Build sed script from placeholders + .exocortex.env (env_get).
    local sed_args=()
    local ph val
    for ph in "${PLACEHOLDERS[@]}"; do
        val=$(env_get "$ph")
        sed_args+=(-e "s|{{$ph}}|$val|g")
    done

    if [ ${#sed_args[@]} -gt 0 ]; then
        sed_inplace "${sed_args[@]}" "$dst"
    fi

    # Preserve executable bit (.sh files always get +x вЂ” git may track 100644 after updates)
    if [ -x "$src" ] || [[ "$rel" == *.sh ]]; then
        chmod +x "$dst"
    fi

    # Verify no unsubstituted placeholders remain
    if grep -qE '\{\{[A-Z_]+\}\}' "$dst" 2>/dev/null; then
        echo "  вљ  $rel: РѕСЃС‚Р°Р»РёСЃСЊ РЅРµР·Р°РјРµРЅС‘РЅРЅС‹Рµ РїР»РµР№СЃС…РѕР»РґРµСЂС‹:" >&2
        grep -oE '\{\{[A-Z_]+\}\}' "$dst" | sort -u | sed 's/^/      /' >&2
    fi
}

copy_to_workspace_file() {
    local rel="$1"
    local src="$TEMPLATE_DIR/$rel"
    local dst="$BUILD_DIR/workspace/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    case "$dst" in *.sh) chmod +x "$dst" ;; esac
}

# Process substituted
for f in "${SUBSTITUTED_FILES[@]}"; do
    build_substituted_file "$f"
done

# Process copied_to_workspace
for f in "${COPIED_FILES[@]}"; do
    copy_to_workspace_file "$f"
done

# === Stamp build hash + version ===
{
    echo "$INPUT_HASH"
    echo ""
    echo "FMT version: $FMT_VERSION"
    echo "Overlay version: $(grep -m1 '^version:' "$OVERLAY_FILE" | sed 's/version:[[:space:]]*//')"
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUILD_DIR/runtime/.build-hash"

# === Diff mode ===
if $DIFF_MODE; then
    if [ ! -d "$RUNTIME_DIR" ]; then
        echo "[diff] $RUNTIME_DIR РЅРµ СЃСѓС‰РµСЃС‚РІСѓРµС‚ вЂ” Р±СѓРґРµС‚ СЃРѕР·РґР°РЅ СЃ РЅСѓР»СЏ."
        echo "  Substituted: ${#SUBSTITUTED_FILES[@]} С„Р°Р№Р»РѕРІ"
        echo "  Copied to workspace: ${#COPIED_FILES[@]} С„Р°Р№Р»РѕРІ"
        exit 0
    fi

    DRIFT_COUNT=0
    for f in "${SUBSTITUTED_FILES[@]}"; do
        existing="$RUNTIME_DIR/$f"
        new="$BUILD_DIR/runtime/$f"
        if [ ! -f "$existing" ]; then
            echo "[diff] NEW: $f"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        elif ! cmp -s "$existing" "$new"; then
            echo "[diff] CHANGED: $f"
            diff -u "$existing" "$new" 2>/dev/null | head -20 | sed 's/^/  /'
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        fi
    done

    if [ "$DRIFT_COUNT" -eq 0 ]; then
        echo "[diff] runtime in sync (0 changes)"
        exit 0
    else
        echo ""
        echo "[diff] $DRIFT_COUNT С„Р°Р№Р»РѕРІ РёР·РјРµРЅРёР»РѕСЃСЊ Р±С‹. Р—Р°РїСѓСЃС‚РёС‚Рµ Р±РµР· --diff РґР»СЏ РїСЂРёРјРµРЅРµРЅРёСЏ."
        exit 5
    fi
fi

# === Dry-run mode ===
if $DRY_RUN; then
    echo "[dry-run] Р‘СѓРґРµС‚ СЃРѕР·РґР°РЅРѕ РІ $RUNTIME_DIR/:"
    for f in "${SUBSTITUTED_FILES[@]}"; do
        echo "  ~ $f (substituted)"
    done
    echo ""
    echo "[dry-run] Р‘СѓРґРµС‚ СЃРєРѕРїРёСЂРѕРІР°РЅРѕ РІ $WORKSPACE_DIR/:"
    for f in "${COPIED_FILES[@]}"; do
        echo "  + $f"
    done
    echo ""
    echo "[dry-run] Build hash (РґР»СЏ drift detection): ${INPUT_HASH:0:16}..."
    echo "[dry-run] Р‘РµР· РёР·РјРµРЅРµРЅРёР№ РЅР° РґРёСЃРєРµ."
    exit 0
fi

# === Atomic swap: replace runtime + copy workspace files ===
# WP-273 0.29.4 R6.3 fix: flock РЅР° $WORKSPACE_DIR/.iwe-runtime.lock вЂ” РїСЂРµРґРѕС‚РІСЂР°С‰Р°РµС‚
# race window РјРµР¶РґСѓ РґРІСѓРјСЏ РѕРґРЅРѕРІСЂРµРјРµРЅРЅС‹РјРё build-runtime РР›Р build-runtime + scheduler.
# scheduler.sh С‚РѕР¶Рµ Р±РµСЂС‘С‚ shared lock РЅР° СЌС‚РѕС‚ С„Р°Р№Р» РїРµСЂРµРґ С‡С‚РµРЅРёРµРј runner-РїСѓС‚РµР№.
mkdir -p "$WORKSPACE_DIR"
LOCK_FILE="${WORKSPACE_DIR}/.iwe-runtime.lock"

# РСЃРїРѕР»СЊР·СѓРµРј flock РµСЃР»Рё РґРѕСЃС‚СѓРїРµРЅ (Linux РІСЃРµРіРґР°; macOS вЂ” С‡РµСЂРµР· util-linux brew, optional)
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -x -w 30 9; then
        echo "ERROR: build-runtime: РЅРµ СѓРґР°Р»РѕСЃСЊ РїРѕР»СѓС‡РёС‚СЊ exclusive lock РЅР° $LOCK_FILE Р·Р° 30 СЃРµРє" >&2
        exit 6
    fi
fi

# 1. Replace .iwe-runtime/ atomically (РїРѕРґ lock'РѕРј вЂ” РЅРёРєС‚Рѕ РЅРµ С‡РёС‚Р°РµС‚ РІ СЌС‚РѕС‚ РјРѕРјРµРЅС‚)
RUNTIME_OLD="${RUNTIME_DIR}.old.$$"
if [ -d "$RUNTIME_DIR" ]; then
    mv "$RUNTIME_DIR" "$RUNTIME_OLD"
fi

mv "$BUILD_DIR/runtime" "$RUNTIME_DIR"

# Cleanup old runtime
[ -d "$RUNTIME_OLD" ] && rm -rf "$RUNTIME_OLD"

# Lock РѕСЃРІРѕР±РѕР¶РґР°РµС‚СЃСЏ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РїСЂРё exit (FD 9 Р·Р°РєСЂС‹РІР°РµС‚СЃСЏ)

# 2. Copy workspace files (РќР• atomic вЂ” СЌС‚Рѕ РЅРµ РєСЂРёС‚РёС‡РЅРѕ, С„Р°Р№Р»С‹ РЅРµР·Р°РІРёСЃРёРјС‹)
COPIED_COUNT=0
for f in "${COPIED_FILES[@]}"; do
    src="$BUILD_DIR/workspace/$f"
    dst="$WORKSPACE_DIR/$f"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        : # skip вЂ” identical
    else
        cp "$src" "$dst"
        COPIED_COUNT=$((COPIED_COUNT + 1))
    fi
done

if ! $QUIET; then
    echo "вњ“ runtime: ${#SUBSTITUTED_FILES[@]} С„Р°Р№Р»РѕРІ РІ $RUNTIME_DIR/"
    echo "вњ“ workspace: $COPIED_COUNT С„Р°Р№Р»РѕРІ РѕР±РЅРѕРІР»РµРЅРѕ / ${#COPIED_FILES[@]} РїСЂРѕРІРµСЂРµРЅРѕ"
    echo "  Build hash: ${INPUT_HASH:0:16}..."
    echo "  FMT version: $FMT_VERSION"
fi

exit 0
