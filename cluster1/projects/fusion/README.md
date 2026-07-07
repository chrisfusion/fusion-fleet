# projects/fusion/ (cluster1)

Placeholder — mirrors `dev-cluster/projects/fusion/` exactly, minus the `dev`/`staging`/`personal`
channels (those are dev-cluster-only concepts). Production uses only the `stable` channel:

- `base/` — shared, canonical `HelmRelease` per microservice (chart ref + values common to every
  instance). Empty for now, awaiting your production HelmRelease values.
- `stable/<instance>/` — one namespaced production instance, tracking a pinned release tag. Same
  shape as a dev-cluster instance (namespace.yaml, kustomization.yaml referencing `../../base` +
  instance-specific patches, flux-kustomization.yaml, optional `jobs/` for your Postgres
  install/preseeding Jobs). Not created yet — add it once the base HelmReleases exist.
