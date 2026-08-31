# krypton-umbrella

Helm umbrella chart for the Krypton platform, deployed by ArgoCD to
Kubernetes/OpenShift. All subcharts share one library chart (`krypton-lib`)
that enforces the platform naming convention, standard labels, merged
annotations and dynamic ArgoCD sync waves.

## Layout

```
krypton-umbrella/
├── Chart.yaml                  # declares all charts under charts/ (required by Helm 4)
├── values.yaml                 # global: lane, static labels/annotations, default sync waves
├── values.schema.json          # validates the umbrella keys, esp. global
└── charts/
    ├── krypton-lib/            # type: library - renders nothing, provides helpers
    │   └── templates/_helpers.tpl
    ├── krypton-banking/        # Deployment, Service, ConfigMap, VaultStaticSecret, Route,
    │                           # ServiceAccount (+ optional PDB / HPA / NetworkPolicy)
    └── krypton-auth/           # Deployment, ServiceAccount
```

Each subchart declares the library as a local dependency:

```yaml
dependencies:
  - name: krypton-lib
    version: 0.1.0
    repository: file://../krypton-lib
```

When the umbrella renders, Helm loads every chart's templates into one shared
namespace, so the `krypton-lib.*` helpers resolve without vendoring. The
`file://` dependency additionally lets each subchart be built and rendered
standalone (see below).

## Conventions

**Resource names** - `krypton-lib.componentName` produces
`<subchart-name>-<global.laneName>-<component-shortname>`, e.g.
`krypton-banking-release-deploy`. The name suffix is the component type's
Kubernetes shortname as registered in the catalog (`configMap` → `cm`,
`service` → `svc`); types without an upstream shortname fall back to the
kebab-cased type (`vaultStaticSecret` → `vault-static-secret`). Labels and
annotations keep the full kebab-cased type (`config-map`) - only names are
shortened. When a subchart renders several resources of the same component
type, an optional `instance` argument is appended as one more kebab-cased
suffix (`krypton-banking-release-vault-static-secret-database`). Rendering
fails loudly if `global.laneName` is unset.

**Label domain** - the platform-generated label/annotation keys
(`<domain>/lane`, `<domain>/component`, `<domain>/source-chart`) take their
prefix from `global.labelDomain` (default `krypton.io`), so the scaffold can
be rebranded per project with one values key; the static keys under
`global.labels`/`global.annotations` are plain values and are edited
alongside. `app.kubernetes.io/instance` is the Helm release name (the
ArgoCD Application name), not a hardcoded value.

**Workload configuration** - `krypton-lib.image` assembles the image
reference from `image.registry`/`repository`/`tag` (or `digest`); setting
`global.imageRegistry` repoints every subchart at a per-lane proxy or
air-gapped registry with one key. Each subchart runs under its own
ServiceAccount (component `serviceAccount`, wave `-2`, named via
`krypton-lib.serviceAccountName` - bind VaultAuth Kubernetes roles to that
name, or set `serviceAccount.create: false` plus `name:` to reference an
existing SA). `vault.secrets` renders one VaultStaticSecret per entry (the
key becomes the name's instance suffix; `authRef`/`mount`/`refreshAfter`
are shared defaults with per-secret overrides, and `envFrom: true` wires
the materialised Secret into the Deployment); all instances share the
type-level sync wave and prune protection. Secret paths and `route.host`
are rendered through `tpl`, and the default paths template the lane in, so
every lane reads its own secrets. ConfigMap delivery is steered by the
`config` block: `data` holds the keys, `envFrom` exposes them as env vars,
`mountPath` additionally mounts them as kubelet-refreshed files, and
`rollPodsOnChange` gates the checksum rollout &mdash; disable it only for
services that hot-reload their mounted config file themselves, since env
vars never update inside a running container. `resources:` ship per subchart and are sized per lane from the
umbrella. Pod-level passthroughs (`extraEnv`, `extraEnvFrom`,
`podAnnotations`, `nodeSelector`, `tolerations`, `affinity`) go verbatim
into the pod spec, so app teams never fork a template. Optional components
follow the enabled-flag pattern per lane: `podDisruptionBudget` (the
release lane enables it for banking), `autoscaling` (while enabled the
Deployment stops rendering `spec.replicas`, so ArgoCD and the HPA never
fight over replica counts) and `networkPolicy` (same-namespace plus
OpenShift router ingress).

**Sync waves** - `krypton-lib.syncWave` resolves per component type, first
hit wins:

1. subchart `.Values.syncWaves.<component>` — already contains any umbrella
   override from `<subchart-name>.syncWaves.<component>` (Helm coalescing)
2. `global.syncWaves.<component>` — platform-wide defaults

`krypton-lib.annotations` applies the wave as `argocd.argoproj.io/sync-wave`
last in its merge chain (standard → `global.annotations` → per-call `extra`
→ wave), and omits it when no wave is configured. Current order for
krypton-banking: VaultStaticSecret `-1` → ConfigMap `0` → Deployment/Service
`1` → Route `3`, so the Vault-materialised Secret exists before the
Deployment mounts it, and the Route goes live last. The waves only gate on
real application health because the Deployments carry configurable
readiness/liveness probes (`probes:` in each subchart, overridable per
lane); by default the banking pod template additionally carries a
`checksum/config` annotation so ConfigMap changes roll the pods.

**Cross-subchart ordering** - when one subchart must sync after another,
shift its whole band with `syncWaveOffset` (per subchart, steered from the
umbrella): every resolved wave gets the offset added, and components
without a configured wave - implicitly wave 0 in ArgoCD - are annotated
with the bare offset, so the subchart moves as one block with its internal
order preserved. The umbrella deploys krypton-auth at offset `10`, i.e.
entirely after banking (ServiceAccount `8`, Deployment `11`, while banking
spans `-2..3`). Keep component waves inside `-9..9` and use offset steps of
10 per subchart, then bands never overlap.

**Component catalog** - `krypton-lib.componentCatalog` (in `_helpers.tpl`)
is the single source of truth for component-type strings, and maps each
type to the Kubernetes shortname used in resource names (empty = no
shortname, the kebab-cased type is used instead). Every `component`
argument and every configured `syncWaves`/`syncPrune` key (subchart-level
and global) is checked against it at render time; an unknown string like
`syncWaves.rout` fails the render with the catalog in the error message.
Configuring a catalogued type that a subchart does not (yet) render is
allowed and simply has no effect - waves and prune flags can be staged
before the manifest exists. The catalog covers the common
Kubernetes/OpenShift/VSO kinds; a genuinely new kind is one added line
(type plus shortname, empty for none), no schema edits.

**Value schemas** - every chart ships a `values.schema.json`, validated by
Helm on each lint/template/install against the chart's *coalesced* values.
The schemas are strict about structure (`additionalProperties: false`, so
e.g. a misspelled `syncWave:` block is rejected - even when the typo was
made in the umbrella's subchart block) and about value shapes (waves must
be integers/integer strings, prune flags booleans); component-key
*membership* is the catalog's job, see above. When you add a values key,
extend the chart's schema in the same commit. Keys injected by external
tooling into `global` must be added to the umbrella schema, which is strict
there on purpose.

**Prune protection** - `krypton-lib.syncOptions` resolves per component
through the same chain (subchart/umbrella `syncPrune.<component>` first,
then `global.syncPrune.<component>`). A value of `false` stamps the resource
with `argocd.argoproj.io/sync-options: Prune=false`, so it survives
app-level pruning even when its manifest disappears from git or its subchart
is disabled; ArgoCD then reports the app OutOfSync until the resource is
deleted manually. Setting a key to `true` re-enables pruning for a globally
protected component. Current defaults: all VaultStaticSecrets
(`global.syncPrune`) plus the banking Route (umbrella block) are protected.

**Deploy switches** - every application subchart is gated by a
`condition: <subchart-name>.enabled` flag on its dependency entry in the
umbrella `Chart.yaml`, steered from the umbrella values:

```yaml
krypton-banking:
  enabled: true
```

Set it to `false` in a lane values file (or via ArgoCD `helm.parameters`) to
exclude the whole subchart from the release; ArgoCD then prunes its
resources - except components protected via `syncPrune` (see above). A missing flag counts as enabled, so the flags are declared
explicitly. `krypton-lib` has no condition on purpose: disabling it would
drop the shared helpers from the render namespace and break every enabled
subchart.

## Everyday commands

```bash
helm lint krypton-umbrella
helm template krypton krypton-umbrella                                # render the release lane
helm template krypton krypton-umbrella --set global.laneName=test     # render another lane
```

### Working on a single subchart

Standalone rendering needs the library vendored into the subchart and a lane
supplied (there is no umbrella to provide one):

```bash
helm dependency build krypton-umbrella/charts/krypton-banking
helm template t krypton-umbrella/charts/krypton-banking --set global.laneName=dev
```

The generated `charts/*/charts/` and `charts/*/Chart.lock` are gitignored on
purpose: a stale vendored copy of krypton-lib must never shadow the live one
under `charts/krypton-lib` when the umbrella renders.

### Adding a new component type to a subchart (e.g. a NetworkPolicy)

1. Create the manifest in the subchart's `templates/` using the shared
   metadata helper with a new component-type key:

   ```yaml
   metadata:
     {{- include "krypton-lib.metadata" (dict "ctx" . "component" "networkPolicy") | nindent 2 }}
   ```

   The name suffix comes from the type's catalogued shortname
   (`krypton-banking-release-netpol`); types without one are kebab-cased
   automatically.
2. If (and only if) the kind is genuinely new to the platform, add it to
   `krypton-lib.componentCatalog` in `_helpers.tpl` - one line mapping the
   type to its shortname (empty for none), no schema
   edits. Kinds already in the catalog (networkPolicy is) need no
   registration anywhere, and their `syncWaves`/`syncPrune` entries may even
   be staged before the manifest exists.
3. Give it a wave where it fits the band: `syncWaves.networkPolicy` in the
   subchart values, a platform default under `global.syncWaves`, or a lane
   override in the umbrella's subchart block (e.g. `"0"` so policies exist
   before workloads start).
4. Optionally protect it from pruning: `syncPrune.networkPolicy: false`.

No library changes are needed — naming, labels, annotations, wave and prune
resolution all key off the component string.

### Adding a new subchart

1. `charts/krypton-<name>/` with `Chart.yaml` (declare the `krypton-lib`
   dependency via `file://../krypton-lib`), `values.yaml`,
   `values.schema.json` (copy krypton-auth's as a starting point),
   `templates/`.
2. Add it to the umbrella `Chart.yaml` `dependencies:` list (name + version,
   no repository field — Helm 4 requires every chart in `charts/` to be
   declared) with `condition: krypton-<name>.enabled`, and set
   `enabled: true` in its umbrella values block.
3. Use `krypton-lib.metadata` for every manifest's metadata block; add
   component types to `syncWaves` / `syncPrune` where the global defaults
   don't fit.
4. Optionally add a `krypton-<name>:` block to the umbrella `values.yaml`.

## ArgoCD

Point an Application at this directory; sync waves order the resources
within each sync:

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
    path: krypton-umbrella
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

Per lane, either maintain one values file per lane and add it to
`spec.source.helm.valueFiles`, or set the lane directly:

```yaml
    helm:
      parameters:
        - name: global.laneName
          value: test
```

Verified with Helm v4.2.4 (chart is Helm 3 compatible; no Helm-4-only
features are used).
