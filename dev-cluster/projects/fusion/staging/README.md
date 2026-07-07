# staging channel

Placeholder — no staging instance exists yet.

When one is added, it follows the same shape as `dev/instance_a` (namespace.yaml,
kustomization.yaml referencing `../../base` + instance-specific patches, flux-kustomization.yaml,
optional `jobs/`), with one difference: the channel's ref type is a **pinned tag**, not a branch
(like `stable`, not like `dev`). Each service's HelmRelease patch points `chart.spec.sourceRef.name`
at a `GitRepository` under `dev-cluster/gitrepositories/` tracking that tag — add the `GitRepository`
file first if one doesn't already exist for the tag being promoted.
