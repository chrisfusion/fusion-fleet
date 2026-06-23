# fusion-fleet

Flux fleet manifests for fusion-platform.

## Layout

- `cluster1/`, `cluster2/` — production clusters (placeholder, not yet populated)
- `dev-cluster/` — minikube; this is the Flux bootstrap path (`flux bootstrap --path=./dev-cluster`)
  - `gitrepositories/` — one `GitRepository` per project + ref actually in use, named `<project>-<ref>`
    (e.g. `fusion-spectra-main.yaml`). Instances reference these by name rather than each owning a duplicate,
    so instances on the same ref share one polled source; an instance can move to a different ref by
    pointing at a different `GitRepository` name.
  - `projects/<project>/<channel>/<instance>/` — one namespaced instance of a project
    - `channel` (`dev` / `stable`) indicates which ref the instance's GitRepository tracks
      (`dev` → branch, `stable` → pinned release tag)
    - `flux-kustomization.yaml` — the Flux `Kustomization` CR for this instance (reconciles independently)
    - `kustomization.yaml` — plain kustomize aggregator listing this instance's workload resources
      (`*-helmrelease.yaml`), built by the instance's own `Kustomization` CR
    - the root `dev-cluster/kustomization.yaml` only references each instance's `flux-kustomization.yaml`
      (not its workload files directly), to avoid two reconcilers owning the same resources

## Project granularity

`projects/fusion/` is an umbrella covering all fusion-platform microservices (fusion-spectra, fusion-bff, ...);
each instance directory holds one `HelmRelease` per microservice included in that instance.

## Chart sources

Helm charts live in each project's own repo (not a registry). For local dev, project repos are mirrored
into Gitea (`http://gitea.fusion.local/gitea_admin/<project>.git`) so the in-cluster `GitRepository` source
can reach them without extra credentials.
