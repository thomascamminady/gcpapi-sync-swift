#!/usr/bin/env bash
# Build the DocC documentation of GCPAPISync for static hosting under
# camminady.dev/gcpapi-sync-swift (the GitHub Pages site of this repository).
set -euo pipefail
output="${1:-site}"
graphs="$PWD/.build/docs/symbol-graphs"
module="$graphs/module"
rm -rf "$graphs" "$output"
mkdir -p "$module"
# A separate scratch path, so a cached build cannot skip emitting the symbol graphs.
swift build --target GCPAPISync --scratch-path .build/docs \
    -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc "$graphs"
cp "$graphs"/GCPAPISync*.symbols.json "$module"/
docc=$(command -v docc || echo "xcrun docc")
version=$(sed -n 's/^public let packageVersion = "\(.*\)"$/\1/p' Sources/GCPAPISync/Version.swift)
$docc convert Sources/GCPAPISync/GCPAPISync.docc \
    --additional-symbol-graph-dir "$module" \
    --fallback-display-name GCPAPISync \
    --fallback-bundle-identifier dev.camminady.gcpapi-sync-swift \
    --fallback-bundle-version "$version" \
    --transform-for-static-hosting \
    --hosting-base-path gcpapi-sync-swift \
    --output-path "$output"
echo "Documentation in $output (open $output/documentation/gcpapisync/index.html via a web server)"
