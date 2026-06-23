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
fusion-forge, fusion-index, fusion-content, fusion-weave — the latter's repo is named `fusion-flux` locally
but its actual git origin/chart is `fusion-weave`, use that name for GitRepository/mirror/HelmRelease) — NOT
one folder per repo. Each instance directory holds one `HelmRelease` per microservice included in that
instance.

## Postgres
Don't assume every project needs a fleet-level Postgres `HelmRelease` — check each chart first:
- fusion-forge: bundles its own Postgres as raw manifests in its own chart (`postgresql.enabled`, default
  true) — self-contained, nothing extra needed
- fusion-index: declares Bitnami `postgresql` as a conditional Helm chart *dependency*
  (`postgresql.enabled`, default true) — also self-contained
- fusion-content, fusion-weave: no database
- fusion-bff: the one real gap — takes only an external `db.dsn` value, no bundled/dependency chart. Fleet
  provides this via a standalone `HelmRelease` (`fusion-bff-postgres`) sourced from the public Bitnami
  `HelmRepository` (`https://charts.bitnami.com/bitnami`, chart `postgresql`) with **fixed** (not
  auto-generated) `auth.username`/`auth.password`/`auth.database`, so `fusion-bff`'s own `HelmRelease` patch
  can construct a static DSN pointing at `<postgres-release>-postgresql.<namespace>.svc.cluster.local`

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
- `flux install` (controllers) + bootstrapped: root `GitRepository/flux-system` (this repo) and
  `Kustomization/fleet-dev-cluster`, both in `flux-system`, path `./dev-cluster`
- `GitRepository`/`Kustomization` objects for fleet infra live in `flux-system` namespace; `HelmRelease`
  objects live in the instance's own target namespace (e.g. `fusion-dev-a`)
- `HelmRelease.spec.install.createNamespace: true` only creates the namespace at Helm-install time —
  kustomize-controller still needs the namespace to exist to apply the `HelmRelease` object itself, so each
  instance's `kustomization.yaml` must also include a `namespace.yaml` resource (listed before the
  `HelmRelease`)

## Prerequisite for any project before it gets a fleet instance
Before adding a `projects/<project>/<channel>/<instance>/` for a project, verify its chart templates use
`{{ .Release.Namespace }}`, never a hardcoded/values-driven namespace field. A chart that hardcodes its
namespace will silently render into that namespace regardless of which namespace the `HelmRelease` itself
lives in — and Helm will take ownership of (and overwrite) whatever's already there if names collide. This
caused a real incident with fusion-spectra's chart (fixed); check every other project's chart before its
first instance is added here.

Also grep for **other** `.Values.namespace`/`.Chart.Version` uses beyond the obvious `metadata.namespace`
fields — found and fixed real instances of: an operator's `NAMESPACE` env var (fusion-weave, fusion-forge's
watcher), a postgres DNS hostname helper (fusion-index's `_helpers.tpl`), and an unsanitized
`helm.sh/chart` label using raw `.Chart.Version` (every project) — Flux's `HelmChart` packaging appends
build metadata (e.g. `0.1.0+3`) to the chart version, and `+` isn't valid in a Kubernetes label value, so
this breaks on first Flux-managed install even though manual `helm install` never hits it (manual installs
always use the chart's literal `0.1.0`, no `+N` suffix).

Also check each chart's own namespace-creation toggle (`createNamespace`/`namespaceCreate`/etc.) and set it
to `false` via a values patch if it defaults to `true` — every `HelmRelease` in the same instance shares one
`Namespace` object (created once by the instance's own `namespace.yaml`); letting multiple charts each try
to own/create it risks the same kind of field-manager ownership conflict seen in fusion-spectra's
pre-existing manual-deploy history.

**Incident note**: the first fusion-spectra test instance broke the live manual deployment twice — once
from the namespace bug itself, and again later when upgrading the (by-then-fixed) instance's `HelmRelease`,
because its *release history* still remembered the original broken manifest (resources in the `fusion`
namespace) and Helm pruned them as "no longer present" on the next upgrade. Recovery both times was: suspend
the `HelmRelease`/`Kustomization`s, restore the live namespace's resources directly via `helm upgrade
--install ... -n fusion`, then `helm uninstall` the tainted release in the test namespace before resuming
Flux so the next install starts with clean history. Lesson: fix the chart and verify with `helm template`
*before* ever creating the first `HelmRelease` for a project — never fix-after-broken-install again.

## Values layering for instances
`HelmRelease.spec.chart.spec.valuesFiles` references the chart's own values files (e.g. `values.yaml`,
`values-dev.yaml`) by path relative to the **GitRepository root**, not the chart subdirectory — e.g.
`deployment/values.yaml`, not `values.yaml`, even though `chart.spec.chart: ./deployment`. Reuse the
project's existing values files instead of inlining a full `values:` block per instance. For instance-specific overrides beyond what those files give
(e.g. a different image tag or hostname for one specific instance), add a Kustomize patch in that instance's
`kustomization.yaml` targeting the `HelmRelease`'s `spec.values`, rather than maintaining a divergent copy of
the whole values block.
