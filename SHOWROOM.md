# Showroom mode (plan, not yet implemented)

Goal: a demo/showroom instance of fusion-platform that can be seeded with basic artifacts, chains,
triggers, etc. across all services, and reset back to empty on demand. Not for production clusters.

## Context

The original idea assumed a single cross-service mechanism: tag every seeded object with a common
label (`fusion.io/seed: showroom`) and make reset "delete everything with that label". Research across
fusion-spectra, fusion-bff, fusion-index, fusion-forge and fusion-flux (fusion-weave) showed that
assumption doesn't hold: fusion-weave's objects are real K8s CRDs (labels are free there), but
fusion-index is pure Postgres with no label/metadata column, and fusion-forge's build rows have no
per-object DELETE at all (only a status/age bulk sweep). A uniform label-based design would need schema
and endpoint changes in two other repos before it could work.

The resolution: showroom lives in its **own dedicated fleet instance**, with its own namespace and its
own per-instance Postgres (fusion-index already provisions one per instance, per this repo's own
CLAUDE.md). Because nothing else shares that instance's data, reset doesn't need to identify "which
objects are mine" via a label — it can just **list and delete everything** each service already
exposes via its existing REST API, then reseed. This needs no upstream schema changes, only (mostly)
endpoints that already exist today. Scope is therefore all three services (weave, index, forge) in v1,
not a phased weave-only rollout.

Decisions locked in:
- **Scope**: all three services, via full-reset-then-reseed (not label-based partial cleanup).
- **Seeder code**: new dedicated repo, `fusion-showroom-seeder`, mirrored into Gitea like every other
  project so this fleet's existing `GitRepository`/`HelmRelease` conventions apply unchanged.
- **Trigger**: manual only for v1 — Flux deploys suspended `CronJob`s, an operator runs
  `kubectl create job --from=cronjob/...` on demand. The fusion-spectra Admin-UI button (which would
  need fusion-bff to gain a Kubernetes API client — it currently has none) is explicitly deferred to a
  later phase, not part of this plan.

## New repo: `fusion-showroom-seeder`

A small Go CLI (matches the idiom of every other backend service here — bff/forge/weave are all Go),
with two subcommands, `reset` and `seed`. One package per target service (`internal/index`,
`internal/forge`, `internal/weave`), each implementing:

```go
type Resetter interface { Reset(ctx context.Context) error }
type Seeder   interface { Seed(ctx context.Context) error }
```

**Auth**: reuse fusion-bff's existing pattern exactly, don't invent a new one — a projected
ServiceAccount token read from disk with TTL-based refresh (mirror
`fusion-bff/internal/token/provider.go`'s `FileProvider`), sent as `Authorization: Bearer <token>` to
each service's REST API. The seeder's ServiceAccount needs the `fusion-platform.io/role: admin` label
(same mechanism fusion-bff's target services already read off the calling ServiceAccount via
TokenReview — see `fusion-flux/internal/apiserver/middleware/rbac.go`), since weave's DELETE routes
require the `admin` role. **Verify during implementation**: fusion-bff mints its index/forge token with
an explicit `audience: fusion-bff` (see its `deployment.yaml`) — confirm whether index/forge's
TokenReview validation actually checks that audience string, or accepts any valid in-cluster token; if
it's checked, the seeder must request the same audience.

**Reset, per service** (no bulk-delete-by-filter exists for two of these — must list then loop):
- **fusion-weave**: `GET`-list + `DELETE :name` loop over chains, triggers, job templates, service
  templates, runs (`internal/apiserver/handlers/*.go` in fusion-flux) — CRDs, no bulk endpoint.
- **fusion-index**: `GET /api/v1/artifacts` (confirmed exists, `internal/api/router.go:55`) +
  `DELETE /api/v1/artifacts/:id` per artifact. Verify during implementation whether deleting an artifact
  cascades its versions/files/tags server-side, or whether those need their own list+delete pass first.
- **fusion-forge**: `DELETE /api/v1/builds` bulk endpoint (`internal/api/handlers/builds.go`) with
  `older_than` set to "now" and `statuses` covering the non-active states — **note it explicitly rejects
  `PENDING`/`BUILDING`**, so an in-flight build survives a reset call. This is a known limitation, not a
  blocker: document that reset assumes no build is actively running at reset time; a stuck build needs
  `zombie-cleanup` or a manual CR delete. Also `GET`-list + `DELETE :name` loop over `GitWatcher` objects
  (real CRD, `internal/api/handlers/gitwatchers.go`).

**Seed**: after reset, `POST` a small fixed demo dataset in dependency order — index artifacts/versions
first (weave job templates/chains will reference them by name), then weave job templates → service
templates → chains → triggers. **Exact seed content is still an open question** — don't try to nail it
down in this pass; revisit once the seeder skeleton and reset path are working end-to-end.

**Repo hygiene** (per user's global conventions): GPLv3 license; a `Dockerfile` to verify the build
(this is a Go binary, so a multi-stage build); a `deployment/` dir holding a small Helm chart (matches
every other project here — chart lives in the project's own repo, sourced via `GitRepository`, never
pulled from a registry) whose templates render two `CronJob`s (see below), a `ServiceAccount`, and
values for each target service's base URL.

## Fleet-side wiring (this repo)

**New dedicated instance**, not a reuse of `instance_a`/`instance_b` (reset wipes to zero — must never
share a namespace with real dev/test data):
`dev-cluster/projects/fusion/dev/showroom/` — same shape as any existing instance (`namespace.yaml` +
one `*-helmrelease.yaml`/`-patch.yaml` per microservice + `flux-kustomization.yaml` targeting e.g.
`fusion-dev-showroom`), built the fast way described in this repo's CLAUDE.md (copy `instance_a`,
sed-replace the namespace string, fix `flux-kustomization.yaml`'s `path:` by hand, add it to the root
`dev-cluster/kustomization.yaml`).

**New `GitRepository`**: `dev-cluster/gitrepositories/fusion-showroom-seeder-main.yaml`, same shape as
the existing ones (e.g. `fusion-forge-main.yaml`):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fusion-showroom-seeder-main
  namespace: flux-system
spec:
  interval: 1m
  url: http://gitea.fusion.local/gitea_admin/fusion-showroom-seeder.git
  ref:
    branch: main
```

**Seeder add-on**, following the monitoring stack's proven sidecar-`Kustomization` pattern exactly
(`dev-cluster/projects/fusion/dev/instance_a/monitoring/flux-kustomization.yaml`) —
`dev-cluster/projects/fusion/dev/showroom/seeder/`:
- `flux-kustomization.yaml` — own `Kustomization` CR, `dependsOn: [fusion-dev-instance-showroom]` (the
  showroom instance's main `Kustomization`, so target Services/Deployments exist first), targeting
  `fusion-dev-showroom`.
- `kustomization.yaml` — aggregates `fusion-showroom-seeder-helmrelease.yaml` (+ a `-patch.yaml` for
  per-instance values: target service base URLs inside `fusion-dev-showroom`).
- The chart's `CronJob` templates: two separate suspended `CronJob`s (`fusion-showroom-seed`,
  `fusion-showroom-reset`), each running the CLI with `seed`/`reset` as the container arg — not one
  `CronJob` with a variable arg, since `kubectl create job --from=cronjob/...` copies the job template
  verbatim and can't inject a different arg at trigger time. `spec.schedule` is required by the K8s API
  even though these never fire on their own — use `suspend: true` plus an inert schedule
  (e.g. `"0 0 30 2 *"`, a date that never occurs).

## Known open items (deliberately not resolved in this pass)

- Exact seed dataset content (which artifacts/chains/triggers make a good demo).
- Whether fusion-index cascades artifact deletion to versions/files/tags, or the seeder needs to do it
  manually in order.
- Whether index/forge's TokenReview validation checks token audience — affects what audience the
  seeder must request when minting its own SA token.
- The fusion-bff Admin-UI trigger (needs a new K8s client in bff) — explicitly deferred, not part of
  this plan.

## Verification (once implemented)

- `fusion-showroom-seeder`: unit-test each service package's list/delete calls against a fake HTTP
  server; `go build` inside the Dockerfile as the build-verification step (per user's global rule to
  always verify builds via a Docker image).
- End-to-end: after Flux reconciles the new `showroom` instance and the seeder add-on, port-forward or
  hit `spectra-showroom.fusion.local` to confirm the instance's microservices are healthy, then manually
  trigger `kubectl create job --from=cronjob/fusion-showroom-seed -n fusion-dev-showroom` and confirm via
  each service's own REST API (or the spectra UI) that artifacts/chains/triggers appear; then trigger the
  `reset` `CronJob` the same way and confirm they're gone.
