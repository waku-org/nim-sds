#!/usr/bin/env bash
# Fails when nix/deps.nix no longer matches nimble.lock, which makes the Nix
# build compile different sources than the Nimble build.
# Usage: ./tools/check-nix-deps.sh [nimble.lock] [nix/deps.nix]
set -euo pipefail

LOCKFILE="${1:-nimble.lock}"
DEPSFILE="${2:-nix/deps.nix}"

command -v jq >/dev/null || { echo "error: jq required"; exit 1; }

status=0

while read -r name rev; do
  if ! grep -q "^  ${name} = pkgs.fetchgit {\$" "$DEPSFILE"; then
    echo "[!] $name is in $LOCKFILE but missing from $DEPSFILE"
    status=1
    continue
  fi
  if ! grep -A3 "^  ${name} = pkgs.fetchgit {\$" "$DEPSFILE" | grep -q "rev = \"${rev}\";"; then
    echo "[!] $name is pinned at $rev in $LOCKFILE, but $DEPSFILE disagrees"
    status=1
  fi
done < <(jq -r '
  .packages
  | to_entries[]
  | select(.value.downloadMethod == "git")
  | select(.key != "nim" and .key != "nimble")
  | "\(.key) \(.value.vcsRevision)"
' "$LOCKFILE")

while read -r name; do
  if ! jq -e --arg n "$name" '.packages | has($n)' "$LOCKFILE" >/dev/null; then
    echo "[!] $name is in $DEPSFILE but not in $LOCKFILE"
    status=1
  fi
done < <(sed -n 's/^  \([A-Za-z0-9_]*\) = pkgs.fetchgit {$/\1/p' "$DEPSFILE")

if [[ $status -eq 0 ]]; then
  echo "[✓] $DEPSFILE is in sync with $LOCKFILE"
else
  echo
  echo "Regenerate with: ./tools/gen-nix-deps.sh $LOCKFILE $DEPSFILE"
fi

exit $status
