<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo-dark.svg">
  <img src="logo.svg" alt="Krypton logo" width="120">
</picture>

# krypton-umbrella

This Helm umbrella chart groups Krypton applications for Kubernetes and OpenShift. Argo CD can render and deploy it. The `krypton-lib` library provides shared template helpers for resource names, labels, annotations, images and ServiceAccounts.

[Deutsch](README.de.md) · [Library reference](charts/krypton-lib/README.md) · [Slim variant](krypton-umbrella-slim/README.md) · [Configuration examples](docs/index.html)

**Library behavior change:** Overlong names are now rejected. Before upgrading configurations that relied on truncation, shorten their inputs and compare the result with deployed resource names. The label composed from `partOfPrefix` and `laneName` must also fit within 63 characters. See the library reference for validation details and limits.

## Terms and layout

- **Umbrella:** the parent chart at the repository root; enables subcharts and overrides their defaults.
- **Subchart:** a dependency such as `krypton-banking`.
- **Library:** reusable template helpers; creates no Kubernetes resources itself.
- **Lane:** a named deployment environment such as `release`, `test` or `dev`. A lane does not automatically create a namespace.
- **Rendering:** combining templates and values into YAML without deploying it.
- **Sync wave:** an integer used by Argo CD to order resources within an Application.

```text
./
├── Chart.yaml                  # dependencies and enable conditions
├── values.yaml                 # global values and subchart overrides
├── values.schema.json          # umbrella validation
├── values-shared-only.yaml      # deploy shared resources only
├── charts/
│   ├── krypton-lib/             # shared helpers
│   ├── krypton-banking/         # Deployment, Service, ConfigMap, VaultStaticSecrets,
│   │                           # Route, ServiceAccount; optional PDB and HPA
│   ├── krypton-auth/            # Deployment and ServiceAccount
│   └── krypton-shared/          # shared ConfigMaps, Secrets, VaultStaticSecrets
│                               # and a namespace NetworkPolicy
└── krypton-umbrella-slim/        # independent chart with a smaller library
```

## Getting started

Run all commands **from the repository root**:

```bash
helm lint .
helm template krypton .
helm template krypton . --set global.laneName=test
```

The defaults are examples. Configure image addresses, Route hosts, Vault paths and credentials before installing. Routes require the OpenShift API. VaultStaticSecrets require the Vault Secrets Operator and a suitable VaultAuth. Rendering does not check those cluster prerequisites.

By default Banking references `krypton-shared-common` and `krypton-shared-gateway`, but does not create them. For a first deployment, provision shared resources separately or enable their creation in exactly one lane:

```bash
helm template krypton-shared . -f values-shared-only.yaml
helm template krypton . --set krypton-shared.enabled=true
```

## Configuring values

Every subchart receives `global` as `.Values.global`. A block named after a subchart overrides its own `values.yaml`. For example, save this as `values-test.yaml`:

```yaml
global:
  laneName: test
krypton-banking:
  replicaCount: 1
  podDisruptionBudget:
    enabled: false
  syncWaves:
    route: "3"
```

```bash
helm template krypton . -f values-test.yaml
```

Setting only `global.laneName=test` does not change replicas, resource limits or the PDB. Helm merges maps and replaces lists; schemas validate the resulting values.

## Names and labels

`krypton-lib.componentName` produces `[<namePrefix>-]<subchart>-<lane>[-<instance>]`. Banking's Deployment, Service, Route and ServiceAccount all use `krypton-banking-release`; their Kubernetes kinds distinguish them. **Neither library appends a kind suffix such as `-cm`.**

Use `instance` for multiple resources of the same kind, for example `database` produces `krypton-banking-release-database`. The helper lowercases the instance and replaces camelCase boundaries and other characters with dashes. Names longer than 63 characters or with an invalid format fail rendering. Final names must remain unique: the example charts check ConfigMap maps, plain Secrets and Vault destination Secrets for normalization collisions. Add the same validation when writing your own resource templates.

| Value | Effect |
| --- | --- |
| `global.laneName` | lane in resource names; required by the umbrella, defaults to `release` |
| `global.namePrefix` | optional prefix for all names, including shared resources |
| `global.partOfPrefix` | prefix only for `app.kubernetes.io/part-of`, e.g. `krypton-release` |
| `global.labelDomain` | prefix of `<domain>/source-chart`; defaults to `krypton.io` |
| `global.labels` | additional resource and Pod labels |
| `global.annotations` | additional resource annotations |

The identity labels `app.kubernetes.io/name`, `app.kubernetes.io/instance` and `app.kubernetes.io/part-of` are reserved. Custom labels cannot override them, so Pod labels always match selectors. The `instance` label is the Helm release name, distinct from the helper's `instance` argument. Argo CD defaults the release name to its Application name; `spec.source.helm.releaseName` can override it. When these names differ, also account for Argo CD's resource-tracking configuration.

Deployment selectors are immutable. Changing `global.partOfPrefix` requires a planned recreation of affected Deployments and can affect availability. Changing the lane creates new resource names. `namePrefix` does not isolate Pod selectors: separate releases also need distinct release/lane identities.

## Shared resources

Passing `shared: true` omits the lane from the name and removes `app.kubernetes.io/part-of`. The name prefix still applies. `krypton-shared` creates these objects from `configMaps`, `secrets` and `vault.secrets`.

**Assign each shared resource name to exactly one Application or Helm release.** The `krypton-shared.enabled` switch controls rendering, but does not enforce ownership across Applications.

| Mode | Values |
| --- | --- |
| Consume existing shared resources | `krypton-shared.enabled: false` (default) |
| One lane also manages shared resources | `krypton-shared.enabled: true` |
| Separate shared Application | use `values-shared-only.yaml` |

Banking and Auth accept instance keys in `sharedEnvFrom.configMaps` and `sharedEnvFrom.secrets`. References use `chart: krypton-shared` and `shared: true`. Matching prefixes produce matching names; this does not guarantee the objects exist or are ready. Sync waves do not coordinate independent Applications.

Banking can also share its own ConfigMap using `config.shared: true`. Exactly one deployment sets `config.create: true`; consumers set it to `false` and reference the same name.

### NetworkPolicy

The full Shared chart can create a NetworkPolicy selecting all namespace Pods. It allows ingress from the same namespace and from OpenShift ingress namespaces selected by labels. `allowRouterHostNetwork` adds the host-network namespace; `extraRules` appends rules.

This is not a guarantee that external traffic can arrive only through Routes: namespace permissions are broader, NetworkPolicies are additive, and enforcement depends on the network plugin. This policy does not restrict egress, but other policies may. See [Kubernetes NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

## Sync waves and prune protection

For each component type, the library first reads the subchart's `syncWaves.<component>` (including umbrella overrides), then `global.syncWaves.<component>`. Zero and negative waves are supported.

`syncWaveOffset` is added to the resolved value. A component without a wave uses base zero when an offset is set. Without a wave or offset, no wave annotation is generated.

Waves and offsets are validated as decimal integers: `"08"` produces `8`, `"010"` produces `10`. Inputs and their sum must fit in the signed 64-bit range; invalid values and overflow fail rendering. Quote padded and very large numbers in YAML. Numeric zero is valid; YAML `null` is not a substitute.

| Subchart | Default order |
| --- | --- |
| Banking | ServiceAccount `-2`, VaultStaticSecrets `-1`, ConfigMap `0`, Deployment/Service/PDB `1`, Route `3` |
| Auth | ServiceAccount `8`, Deployment `11` (offset `10`) |

Choose offsets using actual wave ranges. Local waves `-9..9` require an offset step of at least `19` to avoid overlap; a step of `10` gives overlapping ranges `-9..9` and `1..19`.

Waves order resources within one Argo CD Application and sync phase. An earlier VaultStaticSecret wave does not itself guarantee that the operator has created the destination Secret. Use an appropriate health assessment or explicit readiness check. Pod readiness probes report readiness; liveness probes trigger restarts. See [Argo CD sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

`syncPrune.<component>` has the same precedence as waves. `false` generates `Prune=false`; `true` overrides inherited protection. Schemas accept booleans and the strings `"true"`/`"false"`. VaultStaticSecrets and Banking's Route are protected by default. Prune protection applies during sync; it does not automatically protect against cascading Application deletion. Slim also supports `Delete=false`.

## Calling helpers

Pass a dictionary with `ctx` containing the subchart context: `.` outside a loop, or a saved root context / `$` inside `range`.

```yaml
metadata:
  {{- include "krypton-lib.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

| Helper | Purpose / additional arguments |
| --- | --- |
| `componentName` | name; `component`, optional `instance`, `shared`, `chart` for references |
| `metadata` | name, labels and annotations; accepts naming and annotation arguments |
| `labels` | resource/Pod labels; optional `shared` |
| `selectorLabels` | three Pod identity labels |
| `annotations` | `component`, optional `extra`, `annotation`, `annotationsFrom` |
| `syncWave` / `syncOptions` | resolved Argo CD values for `component` |
| `image` | image reference; optional custom `image` block |
| `serviceAccountName` | generated or existing ServiceAccount name |
| `tplValue` | evaluate `value` as a template using `ctx` |
| `validateResourceNames` | check `configMaps`, `secrets`, `vault.secrets` names; optional `shared` |

Annotation precedence, with later entries winning: generated `<labelDomain>/source-chart` → `global.annotations` → `extra` → `annotation` → `annotationsFrom` → configured sync wave/options.

`extra` is a map; `annotation` is one `key=value` string. `annotationsFrom` is a dotted path under `.Values`, such as `route.annotations`. A missing path contributes nothing; an existing scalar target fails rendering. All merged values are converted to strings. Configure the Argo CD keys through `syncWaves`/`syncPrune`; if no value resolves, a raw Argo CD annotation from an annotation map remains intact.

## Workload configuration

Each subchart's `values.yaml` and schema define its supported options; not every subchart implements every option.

| Area | Behavior |
| --- | --- |
| `image` | `registry/repository:tag`; digest takes precedence, otherwise tag falls back to `Chart.appVersion` |
| `global.imageRegistry` | overrides the registry for subcharts using the image helper |
| `serviceAccount` | `create: true` creates an account, optionally named by `name`; `create: false` references `name` or `default` |
| Banking `vault.secrets` | one VaultStaticSecret per key; per-entry `authRef`, `mount`, `refreshAfter`; `envFrom: true` imports its destination Secret |
| Banking `config` | `create` controls creation, `data` supplies content, `envFrom` imports environment variables, `mountPath` mounts files |
| Banking `config.rollPodsOnChange` | checksum of `config.data` triggers rollout; does not monitor external shared ConfigMaps or Secret updates |
| `probes` | readiness, liveness and optional startup probes |
| `extraEnv`, `extraEnvFrom` | extra container environment entries / references |
| `podAnnotations` | annotations on the Pod template |
| `nodeSelector`, `tolerations`, `affinity` | Pod scheduling |
| Banking `autoscaling` | HPA instead of a fixed Deployment `spec.replicas` |
| Banking `podDisruptionBudget` | optional protection against voluntary disruptions |

Environment variables do not update in running containers. Mounted ConfigMap directories update asynchronously; applications must reload the files themselves. Disable checksum rollouts only when that behavior is sufficient.

## Extending and testing charts

For standalone subchart rendering, build its local library dependency:

```bash
helm dependency build charts/krypton-banking
helm template t charts/krypton-banking --set global.laneName=dev
```

This creates `charts/krypton-banking/charts/` and potentially `Chart.lock`. `.gitignore` only prevents committing these files: Helm can still load them. Remove generated library copies before umbrella tests or use a fresh checkout to avoid stale helpers.

To add a subchart:

1. Create its `Chart.yaml`, `values.yaml`, templates and `values.schema.json`; declare `krypton-lib` with `repository: file://../krypton-lib`.
2. Register it in umbrella dependencies with `condition: krypton-<name>.enabled`; set that flag in umbrella values.
3. **Add its key to `properties` in the umbrella schema**, which rejects unknown keys.
4. Use metadata/selector helpers and validate names for resource maps.
5. Add genuinely new component types to both library catalogs. Catalog shortnames are documentation only.
6. Run lint, render checks and the regression suite:

```bash
python tests/test_charts.py --helm helm
```

The umbrella and application/shared subcharts have schemas; the library does not. Component keys are checked while helpers render resources. Disabled charts without rendered resources do not run these helper checks.

## Argo CD

The chart path for this repository layout is `.`. Replace the example URL and revision:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: krypton-release
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://git.example.com/krypton/krypton-umbrella.git
    targetRevision: main
    path: .
    helm:
      parameters:
        - name: global.laneName
          value: release
  destination:
    server: https://kubernetes.default.svc
    namespace: krypton-release
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

A dedicated shared Application uses the same path and `helm.valueFiles: [values-shared-only.yaml]`. Provision its shared objects before consumers. Check the Helm version used by your Argo CD installation; local rendering is not a target-cluster integration test.

The [Slim variant](krypton-umbrella-slim/README.md) is deployed separately with `path: krypton-umbrella-slim`. Its library focuses on metadata and selector labels; workload configuration remains in the subchart templates.
