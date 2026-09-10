# krypton-umbrella-slim

Slim is an independent umbrella chart. Its `krypton-lib-slim` library standardizes resource names, labels, annotations and Argo CD sync order. It also provides Pod selector labels and resource-name validation. Images, probes, volumes and other workload settings remain in the subchart templates.

[Deutsch](README.de.md) · [Library reference](charts/krypton-lib-slim/README.md) · [Full variant and shared concepts](../README.md) · [Configuration examples](../docs/slim.html)

**Library behavior change:** Overlong names are now rejected. Before upgrading configurations that relied on truncation, shorten their inputs and compare the result with deployed resource names. The label composed from `partOfPrefix` and `laneName` must also fit within 63 characters. See the library reference for validation details and limits.

## Layout and getting started

```text
krypton-umbrella-slim/
├── Chart.yaml
├── values.yaml
├── values.schema.json
├── values-shared-only.yaml
└── charts/
    ├── krypton-lib-slim/       # metadata and selector helpers
    ├── krypton-payments/       # ServiceAccount, ConfigMaps, Secrets,
    │                          # VaultStaticSecrets, Deployment, Service, Route
    ├── krypton-notifier/       # ConfigMap, Deployment and Service
    └── krypton-shared/         # shared ConfigMaps, Secrets, VaultStaticSecrets
```

Run every command on this page **from the repository root**, one level above this chart:

```bash
helm lint krypton-umbrella-slim
helm template krypton krypton-umbrella-slim
helm template krypton krypton-umbrella-slim --set global.laneName=test
```

A **lane** is a deployment environment such as `release` or `test`. Its name changes resource names and lane labels, not resource limits or replica counts. **Rendering** produces YAML without deploying it.

Replace demo images, hosts and secrets before installation. The sample applications require OpenShift Routes, the Vault Secrets Operator and suitable VaultAuth configuration. Payments expects shared objects `krypton-shared-common` and `krypton-shared-gateway` by default.

## Helpers

Pass a dictionary. `ctx` is the subchart context: `.` outside a loop, or a saved root context / `$` inside `range`.

| Helper (prefix `krypton-lib-slim.`) | Arguments besides `ctx` | Result |
| --- | --- | --- |
| `metadata` | `component`; optional `instance`, `shared`, `chart`, `extraLabels`, `extraAnnotations`, `annotation`, `annotationsFrom` | name, labels and annotations |
| `componentName` | `component`; optional `instance`, `shared`, `chart` | name, also for references |
| `labels` | optional `shared`, `extraLabels` | resource/Pod labels |
| `selectorLabels` | none | three Pod identity labels |
| `annotations` | `component`; optional `extraAnnotations`, `annotation`, `annotationsFrom` | merged annotations |
| `syncWave` / `syncOptions` | `component` | resolved value or empty string |
| `validateResourceNames` | optional `shared` | fails on colliding names in resource maps |

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

## Names, instances and references

Names follow `[<namePrefix>-]<subchart>-<lane>[-<instance>]`. The kind is not appended, but `component` remains required for validation and sync settings.

```text
krypton-payments-release             # Deployment, Service, Route, ServiceAccount
krypton-payments-release-app         # ConfigMap and VaultStaticSecret
krypton-payments-release-logging     # another ConfigMap
krypton-payments-release-smtp        # plain Secret
krypton-payments-release-database    # VaultStaticSecret and its destination Secret
```

`instance` distinguishes resources of the same kind. Helpers normalize it and reject complete names longer than 63 characters or with an invalid format. Different inputs can collide: `apiKey` and `api-key` produce the same suffix. Payments and Shared validate final ConfigMap and Secret names, including collisions between plain Secrets and Vault destination Secrets.

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

Use the same helper for references. Set `chart` explicitly when referencing another subchart:

```yaml
- secretRef:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" $ "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true) }}
```

## Shared resources

`shared: true` omits the lane and removes `app.kubernetes.io/part-of`. The global name prefix still applies. Assign each shared resource name to exactly one Application or Helm release; consumers only reference it.

| Mode | Setting |
| --- | --- |
| consume existing shared objects | `krypton-shared.enabled: false` (default) |
| one lane also creates shared objects | `krypton-shared.enabled: true` |
| dedicated shared Application | `values-shared-only.yaml` overlay |

```bash
helm template krypton-shared krypton-umbrella-slim -f krypton-umbrella-slim/values-shared-only.yaml
helm template krypton krypton-umbrella-slim --set krypton-shared.enabled=true
```

Payments imports `sharedEnvFrom.configMaps` and `sharedEnvFrom.secrets` instance keys as container environment variables. Helpers compute names without checking existence. Provision shared objects before consumers; waves do not coordinate separate Applications. Unlike the full variant, Slim has no shared NetworkPolicy.

## Labels and annotations

Label precedence: standard → `global.labels` → subchart `labels` → `extraLabels`. The library then applies the reserved identity labels `app.kubernetes.io/name`, `app.kubernetes.io/instance` and `app.kubernetes.io/part-of`. Custom labels cannot change those values; Pod labels must match selectors. Shared objects omit `part-of`.

The `instance` label contains the Helm release name, normally the Argo CD Application name unless `helm.releaseName` overrides it. The helper's `instance` argument identifies an individual resource within a subchart instead.

Annotation precedence: `<labelDomain>/source-chart` → `global.annotations` → subchart `annotations` → `extraAnnotations` → `annotation` → `annotationsFrom` → configured Argo CD values. All merged values are converted to strings.

- `extraAnnotations`: per-call map.
- `annotation`: one `key=value` string.
- `annotationsFrom`: dotted path under `.Values`, e.g. `route.annotations`. Missing paths are ignored; existing scalar targets fail rendering.

Configured waves/options override raw Argo CD annotations. If no value resolves, a raw annotation remains intact. Configure these keys through `syncWaves` and `syncOptions` for consistent behavior.

## Waves and sync options

For each component type, subchart values (including umbrella overrides) take precedence over globals. `syncWaveOffset` is added; unconfigured waves use base zero for this calculation. All instances of a type share a wave.

Waves and offsets are validated as decimal integers: `"08"` produces `8`, `"010"` produces `10`. Inputs and their sum must fit in the signed 64-bit range; invalid values and overflow fail rendering. Quote padded and very large numbers in YAML. Numeric zero is valid; YAML `null` is not a substitute.

Payments defaults to `-2..3`. Notifier uses offset `10`: ConfigMap `10`, Deployment and Service `11`. These ranges do not overlap. Local waves `-9..9` would require an offset step of at least `19`; steps of ten are not universally sufficient.

An earlier VaultStaticSecret wave does not guarantee that its destination Secret is ready. Operator readiness needs an appropriate health assessment. Waves apply within an Application and sync phase; see [Argo CD sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

`syncOptions.<component>` accepts a list or comma-separated string. A local value replaces the entire global value; `[]` clears an inherited list.

```yaml
global:
  syncOptions:
    vaultStaticSecret: ["Prune=false"]
krypton-payments:
  syncOptions:
    route: ["Prune=false", "Delete=false"]
    vaultStaticSecret: []
```

`Prune=false` protects resources during sync pruning. `Delete=false` also protects against cascading Application deletion. See the [Argo CD sync-options reference](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/) for other options and their effects.

## Values and validation

| Key | Meaning |
| --- | --- |
| `global.laneName` | required by the umbrella; defaults to `release` |
| `global.namePrefix` | optional prefix for every resource name |
| `global.partOfPrefix` | lane-label prefix; part of immutable Deployment selectors |
| `global.labelDomain` | `source-chart` annotation domain; defaults to `krypton.io` |
| `global.labels`, `global.annotations` | shared metadata values |
| `global.syncWaves`, `global.syncOptions` | per-component defaults |
| `labels`, `annotations` | subchart additions |
| `syncWaves`, `syncOptions` | subchart overrides per component |
| `syncWaveOffset` | shift all subchart waves |
| `<subchart>.enabled` | enable the umbrella dependency |

The umbrella schema validates global and library-related subchart values. Slim subcharts have no schemas of their own; other values such as `replicaCount` are not validated there. Standalone subchart rendering does not use the umbrella schema. Component keys are validated when resources call metadata helpers.

Changing `partOfPrefix` on existing Deployments needs a recreation plan. `namePrefix` separates resource names, not Pod selectors. See the [full documentation](../README.md) for details.

## Extending subcharts

```bash
helm dependency build krypton-umbrella-slim/charts/krypton-payments
helm template t krypton-umbrella-slim/charts/krypton-payments --set global.laneName=dev
```

The first command copies the library into the subchart. Generated library copies and `Chart.lock` are gitignored but can still be loaded by Helm. Remove stale copies before umbrella tests or use a fresh checkout.

To add a subchart:

1. Create `Chart.yaml`, `values.yaml` and templates; declare the library through `file://../krypton-lib-slim`.
2. Register its dependency with `condition: krypton-<name>.enabled` and set the values flag.
3. Add `"krypton-<name>": { "$ref": "#/definitions/subchartBlock" }` to umbrella schema `properties`.
4. Use metadata/selector helpers and call `validateResourceNames` for resource maps. Add new component types to both catalogs.
5. Add a subchart schema if workload values should be validated. Run lint, render checks and `python tests/test_charts.py --helm helm`.

## Argo CD

Use the [full variant's Application example](../README.md), with `spec.source.path: krypton-umbrella-slim` and a distinct Application name. A dedicated shared Application also sets `helm.valueFiles: [values-shared-only.yaml]`. This file path is relative to the chart, not the repository root.

`.helmignore` excludes Slim from the full chart. Check the Helm version in your Argo CD installation separately; local rendering does not validate cluster APIs, Vault access or application readiness.
