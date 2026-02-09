#!/usr/bin/env bash

# ============================================================================
# DEPRECATED: This script is deprecated in favor of 'nix develop'.
#
# New workflow:
#   nix develop '.?submodules=1'    # Enter dev shell with Nim + deps ready
#
# This script will be removed in a future release.
# ============================================================================

echo "WARNING: env.sh is deprecated. Use 'nix develop' instead." >&2

# We use ${BASH_SOURCE[0]} instead of $0 to allow sourcing this file
# and we fall back to a Zsh-specific special var to also support Zsh.
REL_PATH="$(dirname ${BASH_SOURCE[0]:-${(%):-%x}})"
ABS_PATH="$(cd ${REL_PATH}; pwd)"
source ${ABS_PATH}/vendor/nimbus-build-system/scripts/env.sh
