# fusion-fleet

Flux fleet manifests for fusion-platform.

## Layout

- `cluster1/`, `cluster2/` — production clusters. Same base+overlay pattern as dev-cluster, but with a
  single `stable` channel (pinned release tag) instead of `dev`/`staging`/`personal`. Directory skeleton
  only for now — production's own instances/config are added separately.
- `dev-cluster/` — minikube; this is the Flux bootstrap path (`flux bootstrap --path=./dev-cluster`)
  - `gitrepositories/` — one `GitRepository` per project + ref actually in use, named `<project>-<ref>`
    (e.g. `fusion-spectra-main.yaml`). Instances reference these by name rather than each owning a duplicate,
    so instances on the same ref share one polled source; an instance can move to a different ref by
    pointing at a different `GitRepository` name.
  - `projects/<project>/base/` — the shared, canonical `HelmRelease` per microservice (chart ref + values
    common to every instance). Never applied directly by Flux — only pulled in by instance
    `kustomization.yaml` files.
  - `projects/<project>/<channel>/<instance>/` — one namespaced instance of a project
    - `channel` is `dev` (shared branch), `staging` (pinned RC tag), `stable` (pinned release tag), or
      `personal` (an individual developer's own branch, one instance dir per developer)
    - `kustomization.yaml` — sets `namespace:`, lists `resources: [namespace.yaml, ../../base, jobs]`, and
      patches only the values that diverge from `base/` for this instance
    - `jobs/` — optional per-instance one-off `Job` manifests (e.g. DB bootstrap), empty until needed
    - `flux-kustomization.yaml` — the Flux `Kustomization` CR for this instance (reconciles independently)
    - the root `dev-cluster/kustomization.yaml` only references each instance's `flux-kustomization.yaml`
      (not `base/` or its workload files directly), to avoid multiple reconcilers owning the same resources

## Project granularity

`projects/fusion/` is an umbrella covering all fusion-platform microservices (fusion-spectra, fusion-bff, ...);
`projects/fusion/base/` holds one `HelmRelease` per microservice, and each instance directory contributes
only namespace + the values that diverge from base for that instance.

## Chart sources

Helm charts live in each project's own repo (not a registry). For local dev, project repos are mirrored
into Gitea (`http://gitea.fusion.local/gitea_admin/<project>.git`) so the in-cluster `GitRepository` source
can reach them without extra credentials.
