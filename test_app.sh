#!/bin/bash
# End-to-end functional test for the live app.
#
# Builds fyles.ae, launches it against a throwaway fixture directory, and
# drives the real window through the AetherUIDriver (the HTTP automation
# server aether_ui ships) to prove the things the headless model tests can't:
# that the grid actually paints the model's listing, that clicking a folder
# descends (path label moves, grid repaints), and that "⬆ .." climbs back.
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

./build/fyles "$FX" >/tmp/aefyles_apptest.log 2>&1 &
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
click() { curl -s -X POST --max-time 4 "http://127.0.0.1:$PORT/widget/$1/click" >/dev/null; sleep 0.6; }

EXPECT_FULL=$'..\nAlpha\nBeta\nzed\nnotes.md\nreadme.txt'

echo "Driving the live UI..."
check "initial path label is the fixture root" "$(extract path)" "$FX"
check "grid shows folders-first, files next, hidden excluded, parent cell on top" "$(extract cells)" "$EXPECT_FULL"

click "$(cell_id 'Alpha')"
check "descended into Alpha (path label moved)" "$(extract path)" "$FX/Alpha"
check "empty Alpha shows only the parent cell" "$(extract cells)" ".."

click "$(cell_id '..')"
check "'⬆ ..' climbed back to the fixture root" "$(extract path)" "$FX"
check "full listing restored after going up" "$(extract cells)" "$EXPECT_FULL"

click "$(cell_id 'Beta')"
check "the grid still navigates after a repaint (into Beta)" "$(extract path)" "$FX/Beta"

echo
if [ "$fail" = 0 ]; then echo "ALL APP TESTS PASSED"; else echo "$fail APP TEST(S) FAILED"; fi
exit "$fail"
