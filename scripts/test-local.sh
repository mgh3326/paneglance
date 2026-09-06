#!/usr/bin/env bash
set -euo pipefail

developer_dir="$(xcode-select -p)"
framework_dir="$developer_dir/Library/Developer/Frameworks"
library_dir="$developer_dir/Library/Developer/usr/lib"

swift test -Xswiftc -F -Xswiftc "$framework_dir" \
  -Xlinker -F -Xlinker "$framework_dir" \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  -Xlinker -rpath -Xlinker "$library_dir"
