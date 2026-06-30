#!/bin/bash
# Headless model tests — no display, no aether_ui. Builds test_model.ae
# (which links only the Aether runtime) and runs it; the process exit code
# is the number of failed assertions, so this script exits non-zero on any
# failure.
set -e
cd "$(dirname "$0")"

# `ae build` caches by entry-file content and can serve a stale compiled dep;
# clear the cache so an edit to model.ae / testutil.ae always rebuilds.
rm -rf ~/.aether/cache/* 2>/dev/null || true
mkdir -p build

echo "Building headless model tests..."
ae build test_model.ae -o build/test_model
echo
./build/test_model
