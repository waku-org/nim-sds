#!/usr/bin/env bash

# This script creates nimble-link files for all vendored Nim submodules.
# It replaces the dependency on nimbus-build-system's create_nimble_link.sh
# by inlining the same logic.
#
# Required env vars:
#   NIMBLE_DIR  — directory where nimble-link packages are created
#                 (e.g., vendor/.nimble)
#
# Optional env vars:
#   EXCLUDED_NIM_PACKAGES — space-separated list of submodule paths to skip

set -euo pipefail

: "${NIMBLE_DIR:?NIMBLE_DIR must be set}"

create_nimble_link() {
  local submodule_dir="$1"
  local module_name
  module_name="$(basename "$submodule_dir")"

  # Only process directories that contain a .nimble file
  if ! ls "$submodule_dir"/*.nimble &>/dev/null; then
    return
  fi

  local pkg_dir
  pkg_dir="$(cd "$submodule_dir" && pwd)"

  # Check exclusions
  for excluded in ${EXCLUDED_NIM_PACKAGES:-}; do
    if [[ "$pkg_dir" =~ $excluded ]]; then
      return
    fi
  done

  # If src/ subdir exists, use it as the package directory
  if [[ -d "$pkg_dir/src" ]]; then
    pkg_dir="$pkg_dir/src"
  fi

  local link_dir="${NIMBLE_DIR}/pkgs/${module_name}-#head"
  local link_path="${link_dir}/${module_name}.nimble-link"

  mkdir -p "$link_dir"

  if [[ -e "$link_path" ]]; then
    echo "ERROR: Nim package already present in '${link_path}': '$(head -n1 "$link_path")'"
    echo "Will not replace it with '${pkg_dir}'."
    echo "Pick one and put the other's relative path in EXCLUDED_NIM_PACKAGES."
    rm -rf "${NIMBLE_DIR}"
    exit 1
  fi

  printf '%s\n%s\n' "$pkg_dir" "$pkg_dir" > "$link_path"
}

process_gitmodules() {
  local gitmodules_file="$1"
  local gitmodules_dir
  gitmodules_dir="$(dirname "$gitmodules_file")"

  # Extract all submodule paths from the .gitmodules file
  grep "path" "$gitmodules_file" | awk '{print $3}' | while read -r submodule_path; do
    local full_path="$gitmodules_dir/$submodule_path"
    if [[ -d "$full_path" ]]; then
      create_nimble_link "$full_path"
    fi
  done
}

# Create the base directory
mkdir -p "${NIMBLE_DIR}/pkgs"

# Find all .gitmodules files and process them
while IFS= read -r -d '' gitmodules_file; do
  echo "Processing .gitmodules file: $gitmodules_file"
  process_gitmodules "$gitmodules_file"
done < <(find . -name '.gitmodules' -print0)
