# krypton-umbrella-slim

The slim variant of the Krypton umbrella. The library chart
(`krypton-lib-slim`) generates the **metadata block** of a manifest and
nothing else:

- unified resource names, with an optional **instance identifier** for
  several resources of the same kind in one subchart
- merged **labels** and **annotations** (platform → umbrella → subchart →
  call site)
- ArgoCD **sync waves** (per component type, with a per-subchart offset)
- ArgoCD **sync options** (any `argocd.argoproj.io/sync-options` entry:
  `Prune=false`, `Delete=false`, `Replace=true`, ...)

Everything below `metadata:` (images, service accounts, probes, volumes,
selectors) is written by the subchart itself. Pick this variant when the app
teams own their manifests and the platform only needs consistent naming,
labelling and ordering; pick the full `krypton-umbrella` when the platform
should also standardise the workload spec.

Written for the Helm 3 line (ArgoCD runs Helm 3): no Helm-4-only features,
repository-less directory dependencies, JSON Schema draft-07.

## Layout

```
krypton-umbrella-slim/
├── Chart.yaml                  # declares all charts under charts/ (Helm 3 tolerates, Helm 4 requires it)
├── values.yaml                 # global: lane, labels/annotations, default waves & sync options
├── values.schema.json          # validates global plus the lib-relevant keys of each subchart block
├── values-shared-only.yaml     # overlay for the shared owner: krypton-shared on, application subcharts off
└── charts/
    ├── krypton-lib-slim/       # type: library - renders nothing, provides the metadata helpers
    │   └── templates/_helpers.tpl
    ├── krypton-payments/       # ServiceAccount, 2 ConfigMaps, 2 Secrets, 2 VaultStaticSecrets,
    │                           # Deployment, Service, Route - instance identifiers in action
    ├── krypton-notifier/       # ConfigMap, Deployment, Service - minimal, wave offset 10
    └── krypton-shared/         # lane-independent ConfigMaps / Secrets / VaultStaticSecrets, one owner per namespace
```

Each subchart declares the library as a local dependency so it can be built
and rendered standalone (`file://../krypton-lib-slim`); under the umbrella
Helm loads every chart's templates into one shared namespace and the
`krypton-lib-slim.*` helpers resolve without vendoring.

## The helpers

Every helper takes one dict; `ctx` is the caller's root context (`.` in a
template, `$` inside a `range`).

| Helper | Arguments | Produces |
| --- | --- | --- |
| `krypton-lib-slim.metadata` | `ctx`, `component`, `instance?`, `extraLabels?`, `extraAnnotations?` | `name:` + `labels:` + `annotations:` |
| `krypton-lib-slim.componentName` | `ctx`, `component`, `instance?` | the resource name (also for cross-references) |
| `krypton-lib-slim.labels` | `ctx`, `extraLabels?` | the merged label map |
| `krypton-lib-slim.selectorLabels` | `ctx` | the immutable identity subset for selectors |
| `krypton-lib-slim.annotations` | `ctx`, `component`, `extraAnnotations?` | the merged annotation map incl. the ArgoCD ones |
| `krypton-lib-slim.syncWave` | `ctx`, `component` | the resolved wave, `""` if none |
| `krypton-lib-slim.syncOptions` | `ctx`, `component` | the comma-joined sync options, `""` if none |

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

### Names and the instance identifier

`componentName` produces `<subchart-name>-<global.laneName>[-<instance>]`,
prefixed with `global.namePrefix` when that is set (`acme` gives
`acme-krypton-payments-release`, shared resources included; empty by
default, so nothing changes).
The component type is deliberately not part of the name - the Kubernetes
kind already tells a Deployment from a Service called `krypton-payments-release`.
The `component` argument is still required: it is validated against the
catalog and selects the sync wave / sync options.

When a subchart renders several resources of one kind, pass an `instance`;
it is appended, normalised to a DNS-1123 label (camelCase boundaries become
dashes, everything is lowercased, other characters become dashes).
krypton-payments renders its ConfigMaps, Secrets and VaultStaticSecrets
from maps and uses the map key as the instance:

```yaml
{{- $root := . -}}
{{- range $name, $data := .Values.configMaps }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" $root "component" "configMap" "instance" $name) | nindent 2 }}
data:
  {{- $data | toYaml | nindent 2 }}
{{- end }}
```

renders (lane `release`):

```
krypton-payments-release               # ServiceAccount, Deployment, Service, Route - one name, four kinds
krypton-payments-release-app           # ConfigMap "app" and VaultStaticSecret "app" - different kinds
krypton-payments-release-logging       # ConfigMap
krypton-payments-release-smtp          # Secret
krypton-payments-release-signing       # Secret
krypton-payments-release-database      # VaultStaticSecret (writes the Secret of the same name)
krypton-notifier-release               # ConfigMap, Deployment, Service - no instance
```

Because the kind is the only thing separating resources of one name, two
resources of the *same* kind need distinct instances. The one trap is the
Secret a VaultStaticSecret writes: krypton-payments refuses to render when a
key appears in both `secrets` and `vault.secrets`.

The Deployment references the same names through the same helper, so an
`envFrom` entry and the resource it points to can never drift apart:

```yaml
- secretRef:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" $ "component" "vaultStaticSecret" "instance" $name) }}
```

### Shared resources without the lane

A ConfigMap or Secret that several lane deployments consume only has to
exist once. Pass `shared: true` and the name omits the lane segment, the
`app.kubernetes.io/part-of` lane label is not stamped:

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" $root "component" "secret" "instance" $name "shared" true) | nindent 2 }}
```

```
krypton-payments-smtp                 # instead of krypton-payments-release-smtp
krypton-payments                      # no instance
```

Platform-wide shared objects live in their own subchart, **`krypton-shared`**,
which renders `configMaps`, `secrets` and `vault.secrets` as
`krypton-shared-<key>`. Exactly one ArgoCD Application per namespace may
own them (ArgoCD flags a second owner as a shared resource, Helm refuses
foreign ownership), so ownership is the plain deploy switch
`krypton-shared.enabled`:

| Application | values |
| --- | --- |
| consumer lane (default) | `krypton-shared.enabled: false` - workloads reference the names, nothing is created |
| owning lane | `krypton-shared.enabled: true` next to the enabled application subcharts |
| dedicated shared Application | `-f values-shared-only.yaml` - `krypton-shared` on, every application subchart off |

krypton-payments references them through the same helper that names them,
with `chart` pinning the owner, so a reference can never drift:

```yaml
- secretRef:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" $ "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true) }}
# -> krypton-shared-gateway, exactly what krypton-shared/templates/secrets.yaml renders
```

exposed as `sharedEnvFrom.configMaps` / `.secrets` (instance keys wired in
as `envFrom`; the umbrella wires `common` and `gateway`).

```bash
helm template krypton krypton-umbrella-slim -f krypton-umbrella-slim/values-shared-only.yaml   # just krypton-shared-common / -gateway
helm template krypton krypton-umbrella-slim --set krypton-shared.enabled=true                  # owning lane: everything
```

The catalog (`krypton-lib-slim.componentCatalog` in `_helpers.tpl`) is the
single source of truth for component strings; an unknown `component`
argument or `syncWaves`/`syncOptions` key fails the render with the catalog
in the error message. A genuinely new kind is one added line.

### Labels

Merge order, later wins on key collisions:

1. standard labels: `app.kubernetes.io/name|instance|version|managed-by`,
   `helm.sh/chart`, and the lane as `app.kubernetes.io/part-of` (omitted on
   `shared` resources; `global.partOfPrefix` prepends the umbrella name,
   `krypton-umbrella-slim-release` instead of `release`)
2. `global.labels` — umbrella-wide
3. `<subchart>.labels` — the subchart's `labels:` block, overridable from the
   umbrella's subchart block (the umbrella adds `krypton.io/team: payments`)
4. `extraLabels` — per call

`selectorLabels` is only `app.kubernetes.io/name` + `app.kubernetes.io/instance`
(`instance` is the Helm release name, i.e. the ArgoCD Application name);
never put mutable values into a selector.

### Annotations

1. standard: `<labelDomain>/source-chart`
2. `global.annotations`
3. `<subchart>.annotations` (krypton-notifier gets `krypton.io/on-call` from
   the umbrella)
4. `<subchart>.jenkins.annotations` — CI-injected, **only when the block
   exists**; absent by default, so plain renders carry no CI annotations.
   Jenkins sets it per sync, e.g. via ArgoCD helm parameters
   `krypton-payments.jenkins.annotations.jenkins\.io/build-number=1234`;
   scalar values are stringified, so a numeric build id is safe.
5. `extraAnnotations` — per call; the Route passes `.Values.route.annotations`
   (`haproxy.router.openshift.io/timeout`)
6. `argocd.argoproj.io/sync-wave`
7. `argocd.argoproj.io/sync-options`

The two ArgoCD annotations are applied last and cannot be shadowed; each is
omitted when nothing is configured.

### Sync waves

Resolved per component **type**, first hit wins:

1. `<subchart>.syncWaves.<component>` (subchart values, already coalesced
   with the umbrella's subchart block)
2. `global.syncWaves.<component>`

All instances of a type share the wave: every VaultStaticSecret of
krypton-payments syncs at `-1`, every ConfigMap at `0`. `syncWaveOffset`
(per subchart, set from the umbrella) is added to every resolved wave and
stamps unconfigured components with the bare offset, so a subchart shifts
as one block: krypton-notifier at offset `10` renders ConfigMap `10`,
Deployment/Service `11`, entirely after krypton-payments (`-2..3`). Keep
component waves inside `-9..9` and step offsets by 10.

### Sync options

`syncOptions.<component>` takes a **list** of ArgoCD resource-level sync
options (a comma-separated string works too), same precedence chain as the
waves; the first hit replaces, lists never merge:

```yaml
global:
  syncOptions:
    vaultStaticSecret: ["Prune=false"]            # platform rule

krypton-payments:
  syncOptions:
    route: ["Prune=false", "Delete=false"]         # keep the public Route even if the app is deleted
    vaultStaticSecret: []                          # would switch the platform rule off for this subchart
```

renders `argocd.argoproj.io/sync-options: Prune=false,Delete=false` on the
Route. Other useful entries: `Replace=true`, `ServerSideApply=true`,
`SkipDryRunOnMissingResource=true` (CRD not installed yet), `PruneLast=true`.

### Values contract

| Key | Scope | Meaning |
| --- | --- | --- |
| `global.laneName` | umbrella, **required** | lane; part of every name; render fails when unset |
| `global.namePrefix` | umbrella | optional prefix of every name (`acme-krypton-payments-release`, shared resources included); empty by default |
| `global.labelDomain` | umbrella | prefix of the generated `<domain>/source-chart` annotation, default `krypton.io` |
| `global.labels` / `global.annotations` | umbrella | static maps for every resource |
| `global.syncWaves` / `global.syncOptions` | umbrella | platform defaults per component type |
| `labels` / `annotations` | subchart | custom maps for every resource of the subchart |
| `jenkins.annotations` | subchart, optional | CI-injected annotations; merged only when present |
| `syncWaves` / `syncOptions` | subchart | per-type overrides, win over global |
| `syncWaveOffset` | subchart | shifts the whole band, default `0` |
| `enabled` | umbrella block | deploy switch via `condition:` in the umbrella `Chart.yaml` |

The umbrella `values.schema.json` types exactly these keys (and leaves the
rest of each subchart block to the subchart). The slim variant ships no
per-subchart schemas on purpose; add one to a subchart when you want its
own keys validated.

## Everyday commands

```bash
helm lint krypton-umbrella-slim
helm template krypton krypton-umbrella-slim                              # render the release lane
helm template krypton krypton-umbrella-slim --set global.laneName=test   # another lane
```

Standalone work on one subchart (vendors the library, supplies a lane):

```bash
helm dependency build krypton-umbrella-slim/charts/krypton-payments
helm template t krypton-umbrella-slim/charts/krypton-payments --set global.laneName=dev
```

The generated `charts/*/charts/` and `Chart.lock` files are gitignored.

## Adding a subchart

1. `charts/krypton-<name>/` with `Chart.yaml` (declare `krypton-lib-slim`
   via `file://../krypton-lib-slim`), `values.yaml`, `templates/`.
2. Add it to the umbrella `Chart.yaml` `dependencies:` (name + version, no
   repository) with `condition: krypton-<name>.enabled`, set `enabled: true`
   in the umbrella values, and add `"krypton-<name>": { "$ref": "#/definitions/subchartBlock" }`
   to the umbrella schema.
3. Use `krypton-lib-slim.metadata` for every manifest's metadata block; pass
   an `instance` wherever a kind appears more than once; reference other
   resources through `krypton-lib-slim.componentName`.
4. Set `syncWaves` / `syncOptions` in the subchart or the umbrella block
   where the global defaults do not fit.

## ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: krypton-slim-release
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://git.example.com/krypton/krypton-umbrella.git
    targetRevision: main
    path: krypton-umbrella-slim
    helm:
      parameters:
        - name: global.laneName
          value: release
  destination:
    server: https://kubernetes.default.svc
    namespace: krypton-release
  syncPolicy:
    automated:
      prune: true        # honours the per-resource sync-options annotations
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

ArgoCD runs `helm dependency build` before templating a git-sourced chart;
with repository-less directory dependencies that step only prints
"Assuming it exists in the charts directory" per entry and leaves the
directory charts in place. No `Chart.lock` is committed on purpose: a stale
one would make that step fail with "Chart.lock is out of sync".
