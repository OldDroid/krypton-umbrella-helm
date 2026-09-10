# krypton-lib

[Deutsch](README.de.md)

krypton-lib is a Helm **library chart**. It provides named templates for resource names, labels, annotations and Argo CD settings. It renders no resources of its own. The consuming chart owns Deployments, containers and other resource templates.

## Add the dependency

For sibling directories named `my-app` and `krypton-lib`, declare this in `my-app/Chart.yaml`:

```yaml
apiVersion: v2
name: my-app
version: 0.1.0
dependencies:
  - name: krypton-lib
    version: 0.1.0
    repository: file://../krypton-lib
```

Set this in **the consuming chart's** `values.yaml`:

```yaml
global:
  laneName: test
```

From the parent directory, run `helm dependency build my-app`, then `helm template demo my-app`. A library's `values.yaml` does not supply defaults to its caller. The library has no values schema; a consuming chart should define its own schema. Helper checks cover the cases described below, not every Kubernetes rule.

In this repository, the umbrella already loads the library directory. Building individual subchart dependencies creates additional copies; update or remove stale copies before testing the umbrella. Helm's named-template namespace is shared across the dependency tree.

## Call helpers

Every public helper takes one dictionary. Pass the **calling chart's root context** as `ctx`; Helm has already merged its values and umbrella overrides. `include` returns text: use `nindent` for YAML blocks and `quote` for string fields.

```yaml
metadata:
  {{- include "krypton-lib.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

Inside `range` or `with`, save the root before entering the block:

```yaml
{{- $root := . -}}
{{- range $key, $data := .Values.configMaps }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  {{- include "krypton-lib.metadata" (dict "ctx" $root "component" "configMap" "instance" $key) | nindent 2 }}
data:
  {{- $data | toYaml | nindent 2 }}
{{- end }}
```

| Helper, prefixed with `krypton-lib.` | Arguments besides `ctx` | Result |
| --- | --- | --- |
| `metadata` | `component`; optional `instance`, `shared`, `chart`, `extra`, `annotation`, `annotationsFrom` | Contents of `metadata`: name, labels and annotations |
| `componentName` | `component`; optional `instance`, `shared`, `chart` | Resource name |
| `labels` | optional `shared` | Label map as YAML |
| `selectorLabels` | none | Three Pod identity labels as YAML strings |
| `annotations` | `component`; optional `extra`, `annotation`, `annotationsFrom` | Annotation map as YAML |
| `syncWave`, `syncOptions` | `component` | Resolved value as text, or an empty string |
| `validateResourceNames` | optional `shared` | No output; fails on collisions in supported resource maps |
| `laneName`, `namePrefix`, `partOf`, `labelDomain`, `chart` | none | Lane, name prefix, lane label, annotation domain, or chart/version label |
| `componentCatalog` | none | Accepted component keys as a YAML map |
| `assertComponent` | `component`; optional `origin` | No output; fails on an unknown component |
| `validateComponentConfig` | none | Checks configured component keys in local/global sync maps |
| `image` | optional `image` | Image reference |
| `serviceAccountName` | none | ServiceAccount name |
| `tplValue` | `value` | String evaluated as a template; other values as YAML |

`component` identifies a resource type, such as `deployment` or `secret`. It is required and checked by all helpers that accept it. It is **not appended to names**. Types in the catalog are case-sensitive:

```text
buildConfig clusterRole clusterRoleBinding configMap
cronJob daemonSet deployment horizontalPodAutoscaler
imageStream ingress job networkPolicy
persistentVolumeClaim podDisruptionBudget podMonitor prometheusRule
role roleBinding route secret
service serviceAccount serviceMonitor statefulSet
vaultAuth vaultConnection vaultDynamicSecret vaultStaticSecret
```

Catalog abbreviations are informational. A known but unused type has no effect. Add new types to both catalogs. `syncInteger` is an internal parsing helper, not a caller API.

## Names, labels and references

Resource names follow `[<namePrefix>-]<chart>-<lane>[-<instance>]`. `chart` defaults to `ctx.Chart.Name`; `shared: true` omits the lane. `namePrefix` still applies to shared resources.

Instance normalization inserts `-` between a lowercase letter/digit and a following uppercase letter, lowercases the result, and replaces other characters outside `[a-z0-9-]` with `-`. Thus `apiKey` and `api-key` both become `api-key`. The complete name must fit within 63 characters before one trailing hyphen is removed for compatibility. The result must match `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`; otherwise rendering fails. For example, `abc_` becomes `abc`, but `abc__` still leaves a trailing hyphen and is rejected. Names are never silently truncated. Resource-specific rules may be stricter, for example for a Service starting with a digit.

Call `validateResourceNames` explicitly in `templates/validate.yaml`:

```yaml
{{- include "krypton-lib.validateResourceNames" (dict "ctx" .) -}}
```

Pass `shared: true` there when the corresponding resources use shared names. The helper checks `configMaps` independently, then checks `secrets` and `vault.secrets` together, using each map key as `instance`. A ConfigMap and a Secret may share a name. It does not inspect other maps, charts, releases or cluster objects, and has no `chart` override. Adapt validation for custom naming conventions.

For a reference to another chart, use `componentName` with the owner's chart name:

```yaml
name: {{ include "krypton-lib.componentName" (dict "ctx" . "chart" "krypton-shared" "component" "configMap" "instance" "common" "shared" true) | quote }}
```

Creation and reference must use matching prefix, chart, instance and shared settings, plus matching lanes for lane-specific names. `chart` changes the name only; labels and annotations still describe the caller. Helpers do not verify existence or coordinate ownership: one release/Application must manage each shared resource.

The reserved identity labels are `app.kubernetes.io/name` = calling chart name, `app.kubernetes.io/instance` = Helm release name, and `app.kubernetes.io/part-of` = `[<partOfPrefix>-]<laneName>`. The label named `instance` is unrelated to the resource-name argument. The combined `part-of` value must be a valid nonempty label of at most 63 characters. Shared labels omit `part-of`, while `selectorLabels` always includes it. Use lane-specific labels on the corresponding Pod template. Changing a Deployment selector requires planned resource recreation; `namePrefix` does not change selectors.

## Values and precedence

| Values path | Meaning / default |
| --- | --- |
| `global.laneName` | Required when generating a lane-specific name or label |
| `global.namePrefix` | Optional resource-name prefix; empty by default |
| `global.partOfPrefix` | Optional prefix for the lane label; empty by default |
| `global.labelDomain` | Domain for `<domain>/source-chart`; default `krypton.io` |
| `global.labels`, `global.annotations` | Additional metadata maps |
| `global.syncWaves`, `syncWaves` | Waves per component; a local key overrides the global key |
| `syncWaveOffset` | Added to every resolved component wave; default `0` |
| `global.syncPrune`, `syncPrune` | Prune setting per component; local values take precedence |

Label merge order: Standard → `global.labels`. The three reserved identity values are then reapplied; custom maps cannot override them. Shared resources remove `part-of` after merging.

Annotation merge order: generated source-chart → `global.annotations` → `extra` → `annotation` → `annotationsFrom` → **nonempty** results from `syncWave` and `syncOptions`. Later sources overwrite earlier values. All final label and annotation values are serialized as strings. Supply scalar values; nested lists/maps do not become useful Kubernetes metadata just because they are converted to text. Custom keys and label values are not fully validated by the library.

`annotation` accepts one `key=value` string, splits at the first `=`, and trims whitespace around key and value. A missing `=` or empty key fails rendering. `annotationsFrom` is a dotted path relative to `ctx.Values`, for example `route.annotations`:

| Path result | Behavior |
| --- | --- |
| Missing key, or a scalar/list in an intermediate segment | Adds nothing |
| Reachable final value is YAML `null` | Adds nothing |
| Reachable final value is a map | Merges its entries |
| Reachable final value is a scalar or list | Fails rendering |

Dots separate path segments; literal dots in a key cannot be addressed this way. A Helm values merge may remove a key set to `null` before the helper runs.

## Argo CD settings

Waves and offsets accept integers or strings matching `^-?[0-9]+$`. Decimal strings with leading zeros are supported: `"08"` means `8`, `"010"` means `10`. Quote padded numbers in YAML so the YAML parser does not reinterpret them first. Values and their sum must stay between `-9223372036854775808` and `9223372036854775807`; invalid input and overflow fail rendering. Quote very large integers to preserve their exact value through YAML/JSON parsing.

The first configured key wins: local `syncWaves.<component>`, then global. Explicit numeric zero overrides a global wave; YAML `null` is not the number zero. Add the local offset afterward. Without a wave, a nonzero offset is returned by itself; without a wave and with offset zero, the helper returns an empty string. All instances of one type use the same wave. Offsets must suit actual ranges: local waves `-9..9` need steps of at least `19` to avoid overlap.

`syncPrune.<component>: false` produces `Prune=false`; `true` clears inherited helper protection. Use booleans or the strings `"false"`/`"true"`. The helper compares the value as text with `"false"`; other values produce no protection, so validate the type in the consuming chart. General option lists are available only in Slim.

An empty helper result **does not delete** a raw `argocd.argoproj.io/sync-wave` or `argocd.argoproj.io/sync-options` entry from an annotation map. Clearing inherited helper options therefore does not clear a separately supplied raw annotation. Configure these keys through the sync settings consistently.

Sync waves order resources within an Argo CD Application and phase; they do not coordinate separate Applications or guarantee that an operator has created a destination Secret. `Prune=false` controls sync pruning; protection during Application deletion uses the separate `Delete=false` option. See the official [sync wave](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) and [sync option](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/) documentation.

## Additional full-library helpers

- `image`: Uses a nonempty `image` argument, otherwise `.Values.image`. `repository` is required. `global.imageRegistry` overrides `image.registry`. A digest produces `@digest` and overrides the tag. Without a digest, use `image.tag`, then `Chart.appVersion`; if both are absent, rendering fails. The helper does not check registry reachability or digest syntax.
- `serviceAccountName`: Returns an explicit `.Values.serviceAccount.name` directly. Otherwise `create: true` generates a name through `componentName`; false or unset returns `default`. The helper neither creates nor verifies the account. Explicit names pass through unchanged.
- `tplValue`: Evaluates strings with `tpl` in `ctx`; other values are emitted as YAML. A Vault path can, for example, contain `{{ .Values.global.laneName }}`. Use this only for values intended to support template evaluation.


## Compatibility and verification

This revision replaces silent name truncation with an error and validates composed lane labels, decimal waves and component arguments. Valid names built within 63 characters remain unchanged. Existing configurations that depended on truncation must shorten their inputs before upgrading; compare the resulting names with deployed resources and plan any required rename. This is a behavior change, not an automatic migration. Selector values now remain strings even for values such as `"123"`.

Compared with Slim, the full library adds `image`, `serviceAccountName` and `tplValue`, and uses `extra` and `syncPrune`. Subchart `labels`/`annotations`, `extraLabels`, `extraAnnotations` and general `syncOptions` are read only by Slim. Switching requires more than replacing the helper prefix.

Run `python tests/test_charts.py --helm helm` from the repository root. Tests cover both libraries with real Helm renders, including boundaries and invalid input. Also render the consuming chart with the Helm version used by your deployment system. These checks do not validate CRD availability or admission rules in the target cluster.
