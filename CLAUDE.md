# fusion-fleet

Flux GitOps fleet repo for fusion-platform. Holds `GitRepository`/`HelmRelease`/`Kustomization` manifests
for every fusion-platform project, across all clusters. Helm charts are NOT pulled from a registry — they
live in each project's own repo (e.g. `deployment/` in fusion-spectra) and are sourced via `GitRepository`.

## Clusters
- `cluster1/`, `cluster2/` — production clusters. Same base+overlay pattern as `dev-cluster`
  (`gitrepositories/`, `helmrepositories/`, `projects/<project>/base/` + `projects/<project>/<channel>/
  <instance>/`, root `kustomization.yaml` referencing only `flux-kustomization.yaml` files), but with a
  single channel: `stable` (pinned release tag) — the `dev`/`staging`/`personal` channels are dev-cluster-only
  concepts and don't apply to production. Currently just the directory skeleton (`projects/fusion/base/`
  empty, no `stable/` instances yet) — real HelmRelease values and instances get added once you share your
  production config, including your own per-instance raw manifests (Secrets, ServiceAccount, Ingress, a
  hand-rolled Postgres `Deployment` — see the resource-ordering note under "dev-cluster layout" below; not
  derived from dev-cluster's instances).
- `dev-cluster/` — minikube; this is the Flux bootstrap path (`flux bootstrap --path=./dev-cluster`)

## dev-cluster layout
- `gitrepositories/` — one `GitRepository` per project + ref actually in use, named `<project>-<ref>.yaml`
  (e.g. `fusion-spectra-main.yaml`)
  - Instances reference these by name rather than each owning a duplicate `GitRepository` — instances on
    the same ref share one polled source; an instance moves to a different ref by pointing at a different
    `GitRepository` name (not by editing the shared one)
  - Clean up `GitRepository` files here when no instance references that ref anymore
- `projects/<project>/base/` — the shared, canonical `HelmRelease` for each microservice in the project
  (chart ref + whatever values are actually the same across every instance, e.g. image tag, feature
  toggles). No `metadata.namespace` field — every instance sets it via its own `kustomization.yaml`'s
  `namespace:` transformer. This is a plain `kustomize.config.k8s.io` aggregator, never applied directly by
  Flux — only pulled in as a resource by instance `kustomization.yaml` files.
- `projects/<project>/<channel>/<instance>/` — one namespaced instance of a project
  - `channel` is `dev`, `staging`, `stable`, or `personal` — indicates which kind of ref the instance's
    `GitRepository` tracks and who it's for:
    - `dev` → tracks a shared branch (e.g. `main`) — team test instances like `instance_a`/`instance_b`
    - `staging` → tracks a pinned release-candidate tag, bumped manually to promote a version
    - `stable` → tracks a pinned release tag (documented, not yet used)
    - `personal` → tracks an individual developer's own branch, one instance dir per developer
      (e.g. `personal/alice/`)
  - `namespace.yaml` — the instance's `Namespace` object
  - Raw supporting manifests not covered by any Helm chart (Secrets, a ServiceAccount, Ingress, extra
    Services, a hand-rolled Postgres `Deployment` — always in the *same* namespace as the instance, never
    a shared one) are flat files directly in the instance directory, same as `namespace.yaml` — not inside
    `jobs/` (see below). Not all instances have all of these; only add what's actually needed.
  - `kustomization.yaml` — sets `namespace: <instance-namespace>` (applies to everything pulled in from
    `base/`, but Kustomize leaves the `Namespace` kind itself alone) and lists `resources:` in dependency
    order — **later entries depend on earlier ones existing first**:
    `namespace.yaml` → secrets → serviceaccount(s) → ingress(es) → extra services → postgres deployment →
    `../../base` → `jobs` — plus `patches:` for only the values that genuinely differ from `base/` for this
    instance (hostnames, DSNs, ingress, image tag overrides, etc.). Omit any entry that doesn't apply to a
    given instance (e.g. dev-cluster instances today have none of the raw supporting manifests — dev's
    ingress/postgres come from Helm chart values instead). This ordering applies to both `dev-cluster` and
    `cluster1`/`cluster2` instances.
  - `jobs/` — optional one-off `Job`/`CronJob` manifests for this instance (e.g. a seed/reset trigger, see
    `SHOWROOM.md`) — **not** for persistent workloads like a Postgres `Deployment`, which is a flat file per
    above. Starts as an empty `kustomization.yaml` (`resources: []`) referenced from the instance's own
    `kustomization.yaml`, so adding a Job later needs no structural change, just a new file + resource entry
  - `flux-kustomization.yaml` — the Flux `Kustomization` CR for this instance (one per instance, reconciles
    independently — instance can fail/pause without affecting siblings)
  - **Critical**: the root `dev-cluster/kustomization.yaml` must only reference each instance's
    `flux-kustomization.yaml` file (the CR), never the instance directory, `base/`, or workload files
    directly — otherwise multiple reconcilers would manage the same `HelmRelease`, causing field-manager
    conflicts

## Project granularity
`projects/fusion/` is an umbrella covering all fusion-platform microservices (fusion-spectra, fusion-bff,
fusion-forge, fusion-index, fusion-content, fusion-weave — the latter's repo is named `fusion-flux` locally
but its actual git origin/chart is `fusion-weave`, use that name for GitRepository/mirror/HelmRelease) — NOT
one folder per repo. `projects/fusion/base/` holds one `HelmRelease` per microservice; each instance
directory contributes only namespace + the small set of values that diverge from base for that instance.

`projects/monitoring/dev/shared/` is a separate umbrella for cluster-shared infra (currently just the
Prometheus/Grafana stack) — `dev`/`shared` because there is one instance for the whole dev-cluster, not one
per fusion instance (instance_a/b share it). Don't add a per-instance monitoring stack; wire new scrape
targets into the shared one instead (see below).

## Monitoring (dev-cluster, local only — production has its own separate Grafana/Prometheus)
- `dev-cluster/helmrepositories/prometheus-community.yaml` — Flux `HelmRepository` pointing at the
  upstream `https://prometheus-community.github.io/helm-charts`; this is the **only** third-party
  (non-fusion-platform) chart source in this repo, deliberately separate from `gitrepositories/` since it's
  pulled directly from a Helm repo, not mirrored into Gitea.
- `projects/monitoring/dev/shared/` installs `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager +
  kube-state-metrics + node-exporter) into the `monitoring` namespace, plus the `fusion-grafana` HelmRelease
  (chart lives in the `fusion-grafana` repo) which only adds dashboard ConfigMaps on top — it does not
  deploy Grafana/Prometheus itself.
  - `kubeControllerManager`/`kubeScheduler`/`kubeEtcd`/`kubeProxy` are disabled in values — minikube's
    control plane doesn't expose these reliably and they just produce permanently-down scrape targets.
  - `prometheus.prometheusSpec.serviceMonitorNamespaceSelector: {}` (and the PodMonitor equivalent) — lets
    `ServiceMonitor`/`PodMonitor` objects in `fusion-dev-a`/`fusion-dev-b` (or any future namespace) get
    discovered without per-namespace label wiring.
  - `grafana.sidecar.dashboards.searchNamespace: ALL` — so dashboard ConfigMaps from the `fusion-grafana`
    chart (deployed into `monitoring`) are picked up; default Grafana sidecar behavior only watches its own
    namespace.
  - Grafana reachable at `grafana.fusion.local` (covered by the existing `*.fusion.local` wildcard DNS, see
    fusion-spectra/CLAUDE.md); dev-only admin password is set inline in the HelmRelease values — never reuse
    that value anywhere real.
- **Per-instance scrape targets live next to the instance, not in the monitoring stack's own directory.**
  Each instance that exposes Prometheus metrics gets a `projects/fusion/dev/instance_*/monitoring/` folder
  with its own `ServiceMonitor` + a *separate* `flux-kustomization.yaml` (own `Kustomization` CR) that
  `dependsOn` both `fusion-monitoring-shared` (so the `ServiceMonitor` CRD exists before Flux tries to apply
  one) and the instance's main `fusion-dev-instance-<x>` Kustomization (so the target Service exists first).
  This is deliberately **not** a dependency on the instance's main Kustomization in the other direction —
  the bulk of an instance's microservices (spectra, bff, forge, index, content, weave) must keep deploying
  even if the shared monitoring stack is down or not yet reconciled; only the monitoring-specific add-on
  waits on it. Example: `fusion-weave-servicemonitor.yaml` (in each instance's `monitoring/` folder) selects
  the `fusion-weave-api` Service's `metrics` port, which only exists because `projects/fusion/base/
  fusion-weave-helmrelease.yaml` sets `api.monitoring.enabled: true` (off by default in the chart) — a
  shared value, not a per-instance patch, so every instance gets it.
- **fusion-index's `/q/metrics` is plain JSON, not Prometheus exposition format** — do not add a
  `ServiceMonitor` for it; it will silently scrape nothing useful. Would need a real `/metrics` endpoint
  added upstream (or a JSON-to-Prometheus exporter sidecar) before it can join this stack.

## Adding a new instance
Fastest path: copy an existing instance dir (e.g. `dev/instance_a`) and sed-replace its namespace string
(e.g. `fusion-dev-a` → `fusion-dev-c`) across all files, then trim each patch down to only the values that
still genuinely differ (a fresh instance often needs less overriding than the one you copied from, since
most fields already live in `projects/fusion/base/`). This does NOT catch `flux-kustomization.yaml`'s
`path:` field, which references the instance *directory name* (e.g. `instance_a`) literally — fix that
one by hand. Also add the new `flux-kustomization.yaml` to the root `dev-cluster/kustomization.yaml`.

A `staging` or `personal` instance additionally needs its `GitRepository` ref checked/created in
`gitrepositories/` (a tag for staging, a personal branch for `personal/<devname>`) and each service's patch
overriding `chart.spec.sourceRef.name` to point at it, since `base/` HelmReleases point at the `main`-branch
`GitRepository` by default.

## Real ingress per instance
With the host's wildcard `*.fusion.local` DNS (see fusion-spectra/CLAUDE.md), per-instance ingress
hostnames work with zero `/etc/hosts` edits — convention: `<service>-<instance>.fusion.local` (e.g.
`spectra-b.fusion.local`). Two things to check per chart before patching in a new host:
- ingress value *shape* differs per project — fusion-spectra uses a single `ingress.host` string,
  fusion-bff uses `ingress.hosts: [{host, paths}]`. Read the chart's `ingress.yaml` template, don't
  assume a shape.
- fusion-spectra defaults `ingress.tls.enabled: true` — overriding `ingress.host` also needs
  `ingress.tls.enabled: false` in the same patch, or it dangles a `secretName` with no matching Secret.
- Giving an instance's `fusion-spectra` its own ingress host needs three matching `fusion-bff` config
  overrides on that instance, or browser login breaks (redirects to a dead `localhost:8080`, then 401s
  silently from CORS, then loops back to login even after auth succeeds): `config.oidcBypassBaseUrl`
  (`http://bff-<instance>.fusion.local`), `config.corsOrigins` (`http://spectra-<instance>.fusion.local`),
  `config.postLoginRedirectUrl` (same spectra host) — all default to `localhost`/`/`/unset, fine for a
  single-instance deploy but wrong the moment a second instance gets its own hostname. Also: ConfigMap
  changes alone don't restart the `fusion-bff` pod — `kubectl rollout restart deployment/fusion-bff -n
  <ns>` after reconcile, since these are env vars read once at startup.

## Don't confuse spectra.fusion.local with spectra-a/b.fusion.local
`spectra.fusion.local` is the separate, manually-managed `fusion` namespace deploy (the one described in
fusion-spectra/CLAUDE.md's "Deployment" section) — untouched by pushes to this fleet's `gitea` remote.
The GitOps-managed instances live at `spectra-a.fusion.local` / `spectra-b.fusion.local`. Verifying a
feature "in the browser" after a Flux deploy means the latter, not the former.

## Postgres
Don't assume every project needs its own Postgres — check each chart first, and check whether a project
without a bundled database is actually meant to share an *existing* instance's Postgres (a different
database on the same server) rather than getting a dedicated one:
- fusion-forge: bundles its own Postgres as raw manifests in its own chart (`postgresql.enabled`, default
  true) — self-contained, nothing extra needed
- fusion-index: declares Bitnami `postgresql` as a conditional Helm chart *dependency*
  (`postgresql.enabled`, default true) — also self-contained
- fusion-content, fusion-weave: no database
- fusion-bff: takes only an external `db.dsn` value, no bundled/dependency chart — but it does NOT get its
  own Postgres. The manual-deploy `fusion` namespace's live secret shows it actually points at
  `fusion-index-postgresql` (a different database, `fusion_bff`, on fusion-index's *same* Postgres server),
  confirmed by `fusion-bff/CLAUDE.md`. Per-instance, `fusion-bff`'s `HelmRelease` patch sets
  `db.dsn: postgres://fusion:<password>@fusion-index-postgresql.<namespace>.svc.cluster.local:5432/fusion_bff`
  — same Postgres server, same username/password as `fusion-index`'s own `postgresql.auth.*` values, just a
  different database name. The `fusion_bff` database itself isn't created by any chart — provisioned
  manually once per instance via `kubectl exec ... psql -c "CREATE DATABASE fusion_bff"` against that
  Postgres pod, matching the documented production bootstrap step (see `fusion-bff/CLAUDE.md`: "DB is empty
  on first deploy... manually via kubectl exec on the postgres pod").

## Chart sources (local dev)
Project repos' real origin is `git@work:...` (SSH) — unreachable from inside minikube without a deploy-key
Secret. For local dev, mirror project repos into Gitea instead:
`http://gitea.fusion.local/gitea_admin/<project>.git` (public, no credentials Secret needed).
`GitRepository.spec.url` in `gitrepositories/` points at the Gitea mirror, not the real origin.

Each project repo (including this one) has a `gitea` remote (local mirror, safe to push freely) alongside
its real `origin` (GitHub/work — never push there without explicit per-push confirmation). Flux only ever
watches the `gitea` mirror, so `git push gitea main` is the only push needed to deploy a change.

## Gitea (minikube)
- Namespace `gitea`, ingress `gitea.fusion.local` — resolves automatically via the host's wildcard
  `*.fusion.local` DNS (dnsmasq + systemd-resolved, see fusion-spectra/CLAUDE.md "Local DNS"); no
  `/etc/hosts` entry needed
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

The stale-`HelmChart`-artifact caching bug (delete-and-recreate the `HelmChart` object to force a
rebuild) only seems to hit when amending a chart *after* its `HelmChart` object already exists for that
release — instance_b's brand-new first install of the same (already-fixed) charts didn't trigger it at
all.

Simpler fix, try first: bump the chart's `Chart.yaml` `version` field. `reconcileStrategy: ChartVersion`
only repackages the `HelmChart` artifact when that field changes — a content-only push to the tracked
branch does NOT trigger a redeploy by itself, even though `GitRepository` fetches the new revision.

## CRDs
- Only fusion-weave, fusion-forge and fusion-wizard define CRDs (bff, index, content, spectra have none). Their
  `HelmRelease`s set `install.crds`/`upgrade.crds: CreateReplace`: plain Helm installs a chart's `crds/` but
  never upgrades it, and a stale CRD silently prunes new spec fields on every write (forge's GitWatcher
  missing `spec.autoTag` broke wizard autoPromote; forge's chart also didn't ship that CRD before 0.11.1)
- CRDs are cluster-scoped, shared by every instance on the cluster: only instances on the newest ref may
  manage them — an instance pinned to an older ref gets `crds: Skip` in its patch, or it rolls them back
- `scripts/apply-crds.sh` applies all CRDs from sibling clones (`../fusion-weave` (or `../fusion-flux`),
  `../fusion-forge`, `../fusion-wizard`, each `config/crd/bases/`) to the current kubectl context with
  server-side apply — for clusters/projects without a Flux `HelmRelease` (the wizard has none here yet) or
  to repair a cluster by hand; extra args go to `kubectl apply` (e.g. `--dry-run=server`)

## Values layering for instances
Before referencing a values file in `valuesFiles`, confirm it's actually tracked in git
(`git ls-files | grep values` in the project repo) — files like `values-local.yaml` are commonly
`.gitignore`d (e.g. fusion-content's, to keep real tokens out of git) and will never exist for Flux to
fetch, even though they work fine for a local manual `helm install -f`. If the file is gitignored, inline
the (non-secret) parts you need directly as a Kustomize patch on `HelmRelease.spec.values` instead.

`HelmRelease.spec.chart.spec.valuesFiles` references the chart's own values files (e.g. `values.yaml`,
`values-dev.yaml`) by path relative to the **GitRepository root**, not the chart subdirectory — e.g.
`deployment/values.yaml`, not `values.yaml`, even though `chart.spec.chart: ./deployment`. Reuse the
project's existing values files instead of inlining a full `values:` block per instance. For values that
are the same across every instance (image tag, feature toggles that don't vary), put them directly in
`projects/<project>/base/<service>-helmrelease.yaml`. Only for values that genuinely differ per instance
(hostname, DSN, a one-off image tag override) add a Kustomize patch in that instance's `kustomization.yaml`
targeting the `HelmRelease`'s `spec.values` — never re-copy the whole values block into an instance.
