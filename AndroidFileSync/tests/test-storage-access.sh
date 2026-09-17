#!/bin/bash
set -euo pipefail
AFS_TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd)
AFS_TEST_BUILD=$(mktemp -d /private/tmp/afs-storage-tests.XXXXXX)
xcrun swiftc -parse-as-library -module-cache-path "$AFS_TEST_BUILD/module-cache" \
    "$AFS_TEST_ROOT/AndroidFileSync/Managers/AndroidStorageAccess.swift" \
    "$AFS_TEST_ROOT/tests/AndroidStorageAccessTests.swift" \
    -o "$AFS_TEST_BUILD/storage-access-tests"
"$AFS_TEST_BUILD/storage-access-tests"
