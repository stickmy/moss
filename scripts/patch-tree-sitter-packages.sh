#!/bin/bash
# Patches tree-sitter grammar packages that use FileManager.default.fileExists
# for conditional scanner.c inclusion. This dynamic check fails in Xcode's
# package resolution because the CWD isn't the package root, so scanner.c
# is silently excluded and you get linker errors like:
#   Undefined symbol: _tree_sitter_xxx_external_scanner_create
#
# Current fix: project.yml pins these packages to revisions before the
# fileExists check was introduced. This script is NOT needed for normal builds.
#
# When to use this script:
#   If you need to upgrade a tree-sitter grammar to a newer revision that uses
#   the fileExists pattern, run this script after package resolution to patch
#   the checked-out Package.swift in DerivedData.
#
# Affected packages (as of 2026-04): css, javascript, python, yaml
# See CLAUDE.md "Tree-sitter linker errors" for full details.

set -euo pipefail

DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Moss-*" -type d | head -1)

if [ -z "$DERIVED_DATA" ]; then
  echo "Error: Moss DerivedData not found"
  exit 1
fi

CHECKOUTS="$DERIVED_DATA/SourcePackages/checkouts"
PACKAGES=(tree-sitter-css tree-sitter-javascript tree-sitter-python tree-sitter-yaml)

for pkg in "${PACKAGES[@]}"; do
  manifest="$CHECKOUTS/$pkg/Package.swift"
  if [ ! -f "$manifest" ]; then
    echo "Skip: $pkg (not checked out)"
    continue
  fi

  if grep -q "FileManager.default.fileExists" "$manifest"; then
    sed -i '' 's/var sources = \["src\/parser.c"\]/let sources = ["src\/parser.c", "src\/scanner.c"]/' "$manifest"
    sed -i '' '/FileManager.default.fileExists/,/}/d' "$manifest"
    echo "Patched: $pkg"
  else
    echo "OK:      $pkg (already explicit)"
  fi
done

echo "Done. Run xcodebuild to rebuild."
