# fusion-fleet

Flux GitOps fleet repo for fusion-platform. Holds `GitRepository`/`HelmRelease`/`Kustomization` manifests
for every fusion-platform project, across all clusters. Helm charts are NOT pulled from a registry — they
live in each project's own repo (e.g. `deployment/` in fusion-spectra) and are sourced via `GitRepository`.

## Clusters
- `cluster1/`, `cluster2/` — production clusters (placeholder, not yet populated)
- `dev-cluster/` — minikube; this is the Flux bootstrap path (`flux bootstrap --path=./dev-cluster`)

## dev-cluster layout
- `gitrepositories/` — one `GitRepository` per project + ref actually in use, named `<project>-<ref>.yaml`
  (e.g. `fusion-spectra-main.yaml`)
  - Instances reference these by name rather than each owning a duplicate `GitRepository` — instances on
    the same ref share one polled source; an instance moves to a different ref by pointing at a different
    `GitRepository` name (not by editing the shared one)
  - Clean up `GitRepository` files here when no instance references that ref anymore
- `projects/<project>/<channel>/<instance>/` — one namespaced instance of a project
  - `channel` is `dev` or `stable` — indicates which kind of ref the instance's `GitRepository` tracks
    (`dev` → a branch, `stable` → a pinned release tag)
  - `flux-kustomization.yaml` — the Flux `Kustomization` CR for this instance (one per instance, reconciles
    independently — instance can fail/pause without affecting siblings)
  - `kustomization.yaml` — plain `kustomize.config.k8s.io` aggregator listing this instance's workload
    resources (`*-helmrelease.yaml`); built by the instance's own `Kustomization` CR, NOT by the root
  - **Critical**: the root `dev-cluster/kustomization.yaml` must only reference each instance's
    `flux-kustomization.yaml` file (the CR), never the instance directory or its workload files directly —
    otherwise both the root reconciler and the instance's own `Kustomization` CR would manage the same
    `HelmRelease`, causing field-manager conflicts

## Project granularity
`projects/fusion/` is an umbrella covering all fusion-platform microservices (fusion-spectra, fusion-bff,
fusion-forge, fusion-index, fusion-content) — NOT one folder per repo. Each instance directory holds one
`HelmRelease` per microservice included in that instance.

## Chart sources (local dev)
Project repos' real origin is `git@work:...` (SSH) — unreachable from inside minikube without a deploy-key
Secret. For local dev, mirror project repos into Gitea instead:
`http://gitea.fusion.local/gitea_admin/<project>.git` (public, no credentials Secret needed).
`GitRepository.spec.url` in `gitrepositories/` points at the Gitea mirror, not the real origin.

## Gitea (minikube)
- Namespace `gitea`, ingress `gitea.fusion.local` (add to `/etc/hosts`: `192.168.49.2 gitea.fusion.local`)
- Admin: `gitea_admin` / `gitea_admin_pw`
- nginx ingress needs `nginx.ingress.kubernetes.io/proxy-body-size: 512m` annotation — default 1MB limit
  breaks `git push` of any repo with real history/binaries (set in the gitea Helm values, not just patched
  live, so it survives `helm upgrade`)
- Gitea chart pulls in a `valkey-cluster` (Redis) subchart by default; `redis-cluster.enabled: false` does
  NOT disable it (wrong subchart name for this chart version) — harmless, just don't be surprised by it
- Create repos/tokens via Gitea's REST API instead of the UI: `curl -u admin:pw -X POST
  http://gitea.fusion.local/api/v1/user/repos -d '{"name":"...","auto_init":true}'`; tokens via
  `POST /api/v1/users/{user}/tokens -d '{"name":"...","scopes":["write:repository"]}'`
- Never put credentials in a git remote URL (ends up plaintext in `.git/config`) — use
  `git config credential.helper store` + a token line in `~/.git-credentials` instead

## Environment quirks
- `sudo` has no TTY here — installers that shell out to `sudo` (e.g. `curl ... | sudo bash`) fail with
  "ein Terminal ist erforderlich" instead of prompting. Install user-local (`FLUX_INSTALL_DIR=~/.local/bin`)
  or ask the user to run the sudo command themselves via the `!` prefix

## Flux (minikube)
- Installed via `flux install` (controllers only) into `flux-system` — not yet bootstrapped against this
  repo; nothing is live until that happens
- `GitRepository`/`Kustomization` objects for fleet infra live in `flux-system` namespace; `HelmRelease`
  objects live in the instance's own target namespace (e.g. `fusion-dev-a`)
- `HelmRelease.spec.install.createNamespace: true` only creates the namespace at Helm-install time —
  kustomize-controller still needs the namespace to exist to apply the `HelmRelease` object itself, so each
  instance's `kustomization.yaml` must also include a `namespace.yaml` resource (listed before the
  `HelmRelease`)
