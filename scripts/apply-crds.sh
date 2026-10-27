#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Applies the CRDs of every fusion-platform operator to the current kubectl context.
#
# Helm never upgrades a chart's crds/ directory, and some CRDs are not in any chart at all
# (forge's GitWatcher), so a cluster keeps old CRDs until they are applied by hand. An old
# CRD silently prunes new spec fields (e.g. GitWatcher.spec.autoTag) on every write.
#
# Expects the project repos cloned next to this one (../fusion-weave, ../fusion-forge,
# ../fusion-wizard) on the ref the cluster runs. Reads config/crd/bases/ (controller-gen
# output, the complete set) rather than the charts' crds/ directories.
#
# CRDs are cluster-scoped: every namespace/instance on the cluster shares them, so apply the
# CRDs of the NEWEST ref any instance on the cluster runs (CRD changes are additive).
#
# Usage: scripts/apply-crds.sh [extra kubectl apply args, e.g. --dry-run=server]
# Override a repo location with WEAVE_DIR / FORGE_DIR / WIZARD_DIR.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# First existing directory among the candidates (the weave repo is cloned as fusion-weave,
# but some checkouts name it fusion-flux).
pick_dir() {
  local d
  for d in "$@"; do
    if [[ -d "$d" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

declare -A repos=(
  [weave]="${WEAVE_DIR:-$(pick_dir "$root/fusion-weave" "$root/fusion-flux" || echo "$root/fusion-weave")}"
  [forge]="${FORGE_DIR:-$root/fusion-forge}"
  [wizard]="${WIZARD_DIR:-$root/fusion-wizard}"
)

missing=0
for name in weave forge wizard; do
  crd_dir="${repos[$name]}/config/crd/bases"
  if ! compgen -G "$crd_dir/*.yaml" >/dev/null; then
    echo "error: no CRDs for $name in $crd_dir" >&2
    missing=1
  fi
done
[[ $missing -eq 0 ]] || exit 1

echo "context: $(kubectl config current-context)"
for name in weave forge wizard; do
  crd_dir="${repos[$name]}/config/crd/bases"
  echo "== $name ($crd_dir @ $(git -C "${repos[$name]}" describe --tags --always --dirty 2>/dev/null || echo unknown))"
  # Server-side apply: no last-applied annotation, which large CRDs overflow (262 KiB limit).
  kubectl apply --server-side --force-conflicts --field-manager=fusion-fleet-crds -f "$crd_dir" "$@"
done
