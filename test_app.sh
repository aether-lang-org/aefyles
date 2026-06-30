#!/bin/bash
# End-to-end functional test, driven entirely through the AetherUIDriver.
#
# AetherUIDriver is the HTTP automation server aether_ui ships. This test
# builds fyles.ae, launches the real window, and exercises it ONLY over that
# HTTP API — no special test hooks in the app — to prove what the headless
# model tests can't:
#
#   GET  /widgets              enumerate the live widget tree (sidebar + grid)
#   POST /widget/<id>/click    click a folder cell, a sidebar nav button, "⬆ .."
#   GET  /widgets  (re-read)   assert the path label moved + the grid repainted
#   GET  /screenshot           the window renders to a real PNG
#
# So: the grid paints the model's listing, clicking a folder descends, "⬆ .."
# climbs back, and the sidebar Up/Home navigate — all via AetherUIDriver.
#
# Needs a window server (run it in a desktop session, not pure SSH) plus
# curl and python3. Exit code is the number of failed checks.
set -u
cd "$(dirname "$0")"

PORT="${AEFYLES_TEST_PORT:-9223}"
FX=/tmp/aefyles_apptest
fail=0
check() { # desc  actual  expected
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1"
        echo "         got:  $2"
        echo "         want: $3"
        fail=$((fail + 1))
    fi
}

echo "Building app..."
./build.sh fyles.ae >/tmp/aefyles_build.log 2>&1 || { echo "build failed:"; cat /tmp/aefyles_build.log; exit 1; }

rm -rf "$FX"; mkdir -p "$FX/Alpha" "$FX/Beta" "$FX/zed"
printf x >"$FX/readme.txt"; printf x >"$FX/notes.md"; printf x >"$FX/.secret"

AEFYLES_DRIVER_PORT="$PORT" ./build/fyles "$FX" >/tmp/aefyles_apptest.log 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null; rm -rf "$FX"' EXIT

up=0
for _ in $(seq 1 40); do
    if curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/widgets"; then up=1; break; fi
    sleep 0.3
done
[ "$up" = 1 ] || { echo "test server never came up:"; cat /tmp/aefyles_apptest.log; exit 1; }

# Extract from the live widget tree. The file grid is the sole node of type
# "widget"; the live cells are its current children. (clear_children detaches
# replaced cells to parent 0 but leaves them in the driver's flat registry, so
# we must key on the grid id — not "any button" — to ignore those phantoms.)
extract() { # mode: cells | path
    curl -s --max-time 4 "http://127.0.0.1:$PORT/widgets" | python3 -c '
import sys, json
mode = sys.argv[1]
w = json.load(sys.stdin)
grid = next((x["id"] for x in w if x["type"] == "widget"), None)
if mode == "cells":
    # print just the entry name (drop the leading glyph + spaces) so the test
    # is robust to icon/spacing tweaks in the labels.
    for x in w:
        if x["parent"] == grid and x["type"] == "button":
            print(x["text"].split(None, 1)[-1])
elif mode == "path":
    for x in w:
        if x["type"] == "text" and x["text"].startswith("/"):
            print(x["text"]); break
' "$1"
}
# id of a LIVE grid cell (child of the grid) whose label contains the substring.
cell_id() {
    curl -s --max-time 4 "http://127.0.0.1:$PORT/widgets" | python3 -c '
import sys, json
sub = sys.argv[1]
w = json.load(sys.stdin)
grid = next((x["id"] for x in w if x["type"] == "widget"), None)
for x in w:
    if x["type"] == "button" and x["parent"] == grid and sub in x["text"]:
        print(x["id"]); break
' "$1"
}
# id of a SIDEBAR button (not a grid cell) whose label contains the substring.
nav_id() {
    curl -s --max-time 4 "http://127.0.0.1:$PORT/widgets" | python3 -c '
import sys, json
sub = sys.argv[1]
w = json.load(sys.stdin)
grid = next((x["id"] for x in w if x["type"] == "widget"), None)
for x in w:
    if x["type"] == "button" and x["parent"] != grid and sub in x["text"]:
        print(x["id"]); break
' "$1"
}
click() { curl -s -X POST --max-time 4 "http://127.0.0.1:$PORT/widget/$1/click" >/dev/null; sleep 0.6; }
# yes if any text widget currently reads as the empty-folder message.
empty_present() {
    curl -s --max-time 4 "http://127.0.0.1:$PORT/widgets" | python3 -c '
import sys, json
print("yes" if any(x["type"] == "text" and "empty" in x["text"].lower() for x in json.load(sys.stdin)) else "no")'
}

EXPECT_FULL=$'..\nAlpha\nBeta\nzed\nnotes.md\nreadme.txt'

echo "Driving the live UI..."
check "initial path label is the fixture root" "$(extract path)" "$FX"
check "grid shows folders-first, files next, hidden excluded, parent cell on top" "$(extract cells)" "$EXPECT_FULL"

click "$(cell_id 'Alpha')"
check "descended into Alpha (path label moved)" "$(extract path)" "$FX/Alpha"
check "empty Alpha shows only the parent cell" "$(extract cells)" ".."
check "empty folder shows the empty-state message" "$(empty_present)" "yes"

click "$(cell_id '..')"
check "'⬆ ..' climbed back to the fixture root" "$(extract path)" "$FX"
check "full listing restored after going up" "$(extract cells)" "$EXPECT_FULL"

click "$(cell_id 'Beta')"
check "the grid still navigates after a repaint (into Beta)" "$(extract path)" "$FX/Beta"

# --- sidebar navigation, also via AetherUIDriver ---
check "driver enumerates the sidebar Favourites (Documents present)" \
      "$([ -n "$(nav_id 'Documents')" ] && echo yes)" "yes"

click "$(nav_id 'Up')"
check "sidebar 'Up' button climbs to the fixture root" "$(extract path)" "$FX"

click "$(nav_id '⌂')"
check "sidebar 'Home' button navigates to \$HOME" "$(extract path)" "$HOME"

# --- the AetherUIDriver screenshot endpoint renders the window to a PNG ---
SHOT=/tmp/aefyles_apptest_shot.png
curl -s --max-time 6 "http://127.0.0.1:$PORT/screenshot" -o "$SHOT"
shot_ok=no
if [ -s "$SHOT" ] && head -c 8 "$SHOT" | od -An -tx1 | tr -d ' \n' | grep -qi '^89504e47'; then
    [ "$(wc -c <"$SHOT")" -gt 5000 ] && shot_ok=yes
fi
check "GET /screenshot returns a non-trivial PNG of the window" "$shot_ok" "yes"

echo
if [ "$fail" = 0 ]; then echo "ALL APP TESTS PASSED"; else echo "$fail APP TEST(S) FAILED"; fi
exit "$fail"
