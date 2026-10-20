#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="${BEEB_TEST_DIR:-$PWD/build/tests}"
mkdir -p "$test_dir"
xcrun swiftc -module-cache-path "$test_dir/ModuleCache" BeebHD/BBCService.swift BeebHD/Catalogue.swift BeebHD/Discovery.swift BeebHD/ChannelGuide.swift BeebHD/DASHManifest.swift BeebHD/OfflinePackage.swift Tests/ChannelDownloadTests.swift -o "$test_dir/custom-features"
"$test_dir/custom-features"
