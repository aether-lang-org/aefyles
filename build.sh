#!/bin/bash
# Build an aefyles binary: compile the Aether sources, then link the
# aether-ui native backend for this platform.
#
# Usage: ./build.sh [source.ae] [output-name]
#   source.ae    defaults to fyles.ae
#   output-name  basename only; the binary always lands in build/
#
# The aether-ui checkout supplies both the `aether_ui` module (for aetherc's
# --lib search path) and the platform backend C/Objective-C. Point at it with
# AETHER_UI_DIR; it defaults to a sibling ../aether-ui clone.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AETHER_UI_DIR="${AETHER_UI_DIR:-$(cd "$SCRIPT_DIR/../aether-ui" && pwd)}"
AETHERC="${AETHERC:-aetherc}"

SOURCE="${1:-fyles.ae}"
OUTPUT_NAME="$(basename "${2:-$(basename "$SOURCE" .ae)}")"
OUTPUT="build/${OUTPUT_NAME}"
C_FILE="${OUTPUT}.c"

if [ ! -f "$AETHER_UI_DIR/aether_ui.ae" ]; then
    echo "Error: aether-ui not found at $AETHER_UI_DIR" >&2
    echo "Set AETHER_UI_DIR to your aether-ui checkout." >&2
    exit 1
fi

mkdir -p build

# Aether include/lib flags — works for an installed prefix or a dev tree.
AETHER_INCLUDES="$(ae cflags 2>/dev/null | tr ' ' '\n' | grep -E '^-I' | tr '\n' ' ' || true)"
[ -n "$AETHER_INCLUDES" ] || AETHER_INCLUDES="-I/usr/local/include/aether/runtime -I/usr/local/include/aether/std"
AETHER_LIB_PATH="$(ae cflags --libs 2>/dev/null | tr ' ' '\n' | grep -E '^-L' | head -1 | sed 's/^-L//' || true)"
[ -n "$AETHER_LIB_PATH" ] || AETHER_LIB_PATH="/usr/local/lib/aether"
AETHER_LIBS="$(ae cflags --libs 2>/dev/null || true)"

echo "Compiling $SOURCE -> $C_FILE   (aether_ui from $AETHER_UI_DIR)"
"$AETHERC" --lib "$AETHER_UI_DIR" "$SOURCE" "$C_FILE"

OS="$(uname -s)"
case "$OS" in
    Darwin)
        echo "Platform: macOS (AppKit)"
        clang -O0 -g -fobjc-arc \
            $AETHER_INCLUDES \
            "$C_FILE" \
            "$AETHER_UI_DIR/backend/aether_ui_macos.m" \
            "$AETHER_UI_DIR/backend/aether_ui_system_extras.c" \
            -L"$AETHER_LIB_PATH" -laether \
            -o "$OUTPUT" \
            -framework AppKit -framework Foundation -framework QuartzCore -pthread -lm \
            $AETHER_LIBS
        ;;
    Linux)
        if ! pkg-config --exists gtk4 2>/dev/null; then
            echo "Error: GTK4 dev libraries not found." >&2
            exit 1
        fi
        echo "Platform: Linux (GTK4)"
        LIBNOTIFY_CFLAGS=""; LIBNOTIFY_LIBS=""
        if pkg-config --exists libnotify 2>/dev/null; then
            LIBNOTIFY_CFLAGS="-DAEUI_HAVE_LIBNOTIFY=1 $(pkg-config --cflags libnotify)"
            LIBNOTIFY_LIBS="$(pkg-config --libs libnotify)"
        fi
        gcc -O0 -g -pipe \
            $(pkg-config --cflags gtk4) \
            $AETHER_INCLUDES $LIBNOTIFY_CFLAGS \
            "$C_FILE" \
            "$AETHER_UI_DIR/backend/aether_ui_gtk4.c" \
            "$AETHER_UI_DIR/backend/aether_ui_system_extras.c" \
            "$AETHER_UI_DIR/backend/aether_ui_sni.c" \
            -L"$AETHER_LIB_PATH" -laether \
            -o "$OUTPUT" \
            -pthread -lm $(pkg-config --libs gtk4) $LIBNOTIFY_LIBS $AETHER_LIBS
        ;;
    *)
        echo "Error: unsupported platform '$OS' (macOS and Linux supported here)." >&2
        exit 1
        ;;
esac

echo "Built: $OUTPUT"
