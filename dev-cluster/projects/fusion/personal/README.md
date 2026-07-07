# personal channel

Placeholder — no per-developer instance exists yet.

When one is added (e.g. `personal/alice/`), it follows the same shape as `dev/instance_a`
(namespace.yaml, kustomization.yaml referencing `../../base` + instance-specific patches,
flux-kustomization.yaml, optional `jobs/`), kept separate from the shared `dev/instance_a`/
`instance_b` test instances since a personal instance points at an individual developer's own
branch. Each service's HelmRelease patch overrides `chart.spec.sourceRef.name` to point at a
`GitRepository` under `dev-cluster/gitrepositories/` tracking that branch — add the `GitRepository`
file first if one doesn't already exist for that branch.
