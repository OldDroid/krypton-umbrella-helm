{{/* ==========================================================================
     krypton-lib-slim - metadata-only helpers for Krypton subcharts
     ==========================================================================

     The slim variant of krypton-lib. It generates the METADATA of a manifest
     and nothing else:

       - the unified resource name         krypton-lib-slim.componentName
       - the merged label set              krypton-lib-slim.labels
       - the merged annotation set         krypton-lib-slim.annotations
         incl. the ArgoCD sync wave        krypton-lib-slim.syncWave
         and the ArgoCD sync options       krypton-lib-slim.syncOptions
       - all three in one block            krypton-lib-slim.metadata

     Everything below metadata: (images, service accounts, probes, volumes,
     ...) stays in the subchart's own templates. The only spec-side helper is
     krypton-lib-slim.selectorLabels, because a selector must use exactly the
     identity labels this library stamps onto the pods.

     Call convention: every helper takes ONE argument, a dict built at the
     call site:

         {{ include "krypton-lib-slim.metadata" (dict "ctx" . "component" "configMap" "instance" "logging") }}

       ctx               (required) the caller's root context (`.` inside a
                         subchart template, `$` inside a range). Through it
                         the helpers see the subchart's coalesced .Values
                         (subchart defaults + umbrella overrides + global),
                         its .Chart and the .Release.
       component         (required) the component type of the manifest, e.g.
                         "deployment", "configMap", "secret",
                         "vaultStaticSecret". Validated against the
                         component catalog and drives the sync-wave /
                         sync-options lookup; it is NOT part of the name.
       instance          (optional) identifier that distinguishes several
                         resources of the SAME kind within one subchart -
                         two ConfigMaps, three Secrets, one VaultStaticSecret
                         per Vault path. Appended to the resource name,
                         normalised to a DNS-1123 label.
       shared            (optional) true marks the resource as
                         lane-independent: the name omits the lane segment
                         (<subchart-name>[-<instance>]) and the
                         app.kubernetes.io/part-of lane label is not
                         stamped. For ConfigMaps / Secrets that several lane
                         deployments consume, so they are created once
                         instead of once per lane.
       chart             (optional, componentName only) name of the subchart
                         that OWNS the resource, for templates that reference
                         a resource rendered by another subchart - e.g.
                         "krypton-shared" for the lane-independent ConfigMaps
                         / Secrets. Defaults to the caller's own .Chart.Name.
       extraLabels       (optional) dict merged into the labels with the
                         highest precedence.
       extraAnnotations  (optional) dict merged into the annotations with
                         high precedence (only the two ArgoCD annotations
                         are applied after it).

     Helm loads the templates of every chart in the dependency tree into one
     shared namespace, so these templates are callable from every subchart
     that sits next to krypton-lib-slim underneath the umbrella - and from any
     chart that vendors krypton-lib-slim through its own dependencies.

     Values contract (all keys optional unless stated):

       global.laneName          REQUIRED - lane / environment, part of every name
       global.labelDomain       prefix of generated keys, default krypton.io
       global.labels            static labels for every resource of every subchart
       global.annotations       static annotations, same scope
       global.syncWaves         platform default wave per component type
       global.syncOptions       platform default ArgoCD sync options per type

       .Values.labels           subchart-wide custom labels (umbrella may override)
       .Values.annotations      subchart-wide custom annotations
       .Values.jenkins.annotations
                                CI-injected annotations, merged only when present
       .Values.syncWaves        per-type waves of this subchart (win over global)
       .Values.syncWaveOffset   shifts every wave of this subchart, default 0
       .Values.syncOptions      per-type sync options of this subchart (win over global)
     ========================================================================== */}}


{{/* --------------------------------------------------------------------------
     Lane & label domain
     -------------------------------------------------------------------------- */}}

{{/*
The lane (deployment environment) of this umbrella instance, e.g. "release"
or "test". Fails the render loudly when the umbrella forgot to set it.
*/}}
{{- define "krypton-lib-slim.laneName" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- required "krypton-lib-slim: global.laneName is not set. Define it in the umbrella values.yaml (e.g. laneName: release)." $global.laneName -}}
{{- end }}

{{/*
Value of the app.kubernetes.io/part-of lane label: the lane name, prefixed
with global.partOfPrefix when set (e.g. partOfPrefix "krypton-umbrella-slim"
gives krypton-umbrella-slim-release instead of release). The prefix is a
value because a subchart's .Chart is its own chart - the umbrella's name is
not reachable from inside the library.
*/}}
{{- define "krypton-lib-slim.partOf" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $lane := include "krypton-lib-slim.laneName" . -}}
{{- with $global.partOfPrefix -}}{{- printf "%s-%s" . $lane -}}{{- else -}}{{- $lane -}}{{- end -}}
{{- end }}

{{/*
Domain prefix for the platform-generated annotation key
<domain>/source-chart (the lane itself is carried by the standard
app.kubernetes.io/part-of label). Configurable via global.labelDomain so
the scaffold can be reused for other platforms without touching the library;
defaults to krypton.io.
*/}}
{{- define "krypton-lib-slim.labelDomain" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $global.labelDomain | default "krypton.io" -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Component catalog
     -------------------------------------------------------------------------- */}}

{{/*
Catalog of component types known to the platform - the single source of
truth for what may be passed as a "component" argument and what may appear
as a key under syncWaves / syncOptions. The values are the Kubernetes
shortnames (kubectl api-resources) the full krypton-lib appends to its
resource names; the slim naming scheme (<subchart>-<lane>[-<instance>])
does not use them, the map is nevertheless kept identical to the full
catalog so both variants accept exactly the same component strings.

Configuring a catalogued type that a subchart does not (yet) render is
allowed and simply has no effect - manifests pull their own settings, so
waves / sync options can be staged ahead of the manifest. An uncatalogued
key fails the render instead of being silently ignored.

Extend this map - one camelCase line, no schema edits - when a genuinely
new kind enters the platform.
*/}}
{{- define "krypton-lib-slim.componentCatalog" -}}
buildConfig: bc
clusterRole: ""
clusterRoleBinding: ""
configMap: cm
cronJob: cj
daemonSet: ds
deployment: deploy
horizontalPodAutoscaler: hpa
imageStream: "is"
ingress: ing
job: ""
networkPolicy: netpol
persistentVolumeClaim: pvc
podDisruptionBudget: pdb
podMonitor: pmon
prometheusRule: promrule
role: ""
roleBinding: ""
route: ""
secret: ""
service: svc
serviceAccount: sa
serviceMonitor: smon
statefulSet: sts
vaultAuth: ""
vaultConnection: ""
vaultDynamicSecret: ""
vaultStaticSecret: ""
{{- end }}

{{/*
Fails the render when a component string is not in the catalog.
  ctx        caller context (for the chart name in the error message)
  component  the string to check
  origin     optional, names the source in the error (e.g. "syncWaves key")
*/}}
{{- define "krypton-lib-slim.assertComponent" -}}
{{- $catalog := fromYaml (include "krypton-lib-slim.componentCatalog" .) -}}
{{- if not (hasKey $catalog .component) -}}
{{- fail (printf "krypton-lib-slim: unknown component type %q (chart %q, %s). Known types: %s. Genuinely new kinds are added to krypton-lib-slim.componentCatalog in krypton-lib-slim/templates/_helpers.tpl." .component .ctx.Chart.Name (.origin | default "component argument") (keys $catalog | sortAlpha | join ",")) -}}
{{- end -}}
{{- end }}

{{/*
Validates every component key configured under syncWaves / syncOptions -
both subchart-level and global - against the catalog. Called from
krypton-lib-slim.annotations, so it runs for every rendered manifest: an
unknown key can never be dropped silently, while catalogued-but-unrendered
keys are tolerated by design (pre-staged configuration).
*/}}
{{- define "krypton-lib-slim.validateComponentConfig" -}}
{{- $ctx := .ctx -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- range $k, $_ := $ctx.Values.syncWaves | default dict -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $k "origin" "syncWaves key") -}}
{{- end -}}
{{- range $k, $_ := $global.syncWaves | default dict -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $k "origin" "global.syncWaves key") -}}
{{- end -}}
{{- range $k, $_ := $ctx.Values.syncOptions | default dict -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $k "origin" "syncOptions key") -}}
{{- end -}}
{{- range $k, $_ := $global.syncOptions | default dict -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $k "origin" "global.syncOptions key") -}}
{{- end -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Naming
     -------------------------------------------------------------------------- */}}

{{/*
helm.sh/chart label value: <chart-name>-<chart-version>.
*/}}
{{- define "krypton-lib-slim.chart" -}}
{{- printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
The one sanctioned resource-name format:

    <subchart-name>-<global-lane-name>[-<instance>]
    e.g. krypton-payments-release             Deployment, Service, Route, SA, ...
         krypton-payments-release-logging     ConfigMap, instance "logging"
         krypton-payments-release-database    VaultStaticSecret, instance "database"

  subchart-name   dynamic, from .Chart.Name of the calling subchart
  lane-name       from the umbrella's global.laneName
  instance        optional; the identifier for several resources of the
                  same kind in one subchart. Normalised to a DNS-1123 label:
                  camelCase boundaries become dashes ("logLevel" ->
                  "log-level"), the result is lowercased and every other
                  character outside [a-z0-9-] becomes a dash.

The component type is NOT part of the name - the Kubernetes kind already
tells a Deployment from a Service of the same name. It still has to be
passed: it is validated against the catalog and drives the sync-wave /
sync-options lookup. Consequence: several resources of the SAME kind in one
subchart need distinct instances, and a Secret written by a
VaultStaticSecret (destination.name) must not reuse the instance of a plain
Secret - krypton-payments refuses such a render in secrets.yaml.

"shared" true drops the lane segment for resources that are not lane
specific - a ConfigMap or Secret that every lane deployment of the subchart
consumes and that therefore only has to exist once:
    krypton-payments-app
    krypton-payments-smtp
Use the same call (with "shared" true) both where the resource is created
and where it is referenced, and let exactly ONE deployment create it; the
others reference the name only.

Referencing another subchart's resource: "chart" replaces the caller's
.Chart.Name with the owning subchart's name, everything else stays the
same. This is how the application subcharts point at the objects of the
krypton-shared subchart without spelling out a name - both sides call the
helper with identical arguments, so the reference can never drift:
    krypton-shared/templates/secrets.yaml       (creates)
        (dict "ctx" $root "component" "secret" "instance" "gateway" "shared" true)
    krypton-payments/templates/deployment.yaml  (references)
        (dict "ctx" $ "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true)
    -> krypton-shared-gateway on both sides

Truncated to 63 characters (the Kubernetes name limit for most resources).

Usage:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "component" "deployment") }}
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "component" "configMap" "instance" "logging") }}
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "component" "secret" "instance" "smtp" "shared" true) }}
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true) }}
*/}}
{{- define "krypton-lib-slim.componentName" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.componentName: 'component' is required" .component -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- $name := .chart | default $ctx.Chart.Name -}}
{{- if not .shared -}}
{{- $name = printf "%s-%s" $name (include "krypton-lib-slim.laneName" .) -}}
{{- end -}}
{{- with .instance -}}
{{- $instance := regexReplaceAll "([a-z0-9])([A-Z])" (toString .) "${1}-${2}" | lower -}}
{{- $instance = regexReplaceAll "[^a-z0-9-]" $instance "-" -}}
{{- $name = printf "%s-%s" $name $instance -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Labels
     -------------------------------------------------------------------------- */}}

{{/*
The merged label set for a resource.

Merge order (later wins on key collisions):
  1. chart-generated standard labels (app.kubernetes.io/*, helm.sh/chart);
     the lane is stamped as app.kubernetes.io/part-of: [<partOfPrefix>-]<laneName>
  2. global.labels      - static platform labels from the umbrella
  3. .Values.labels     - custom labels of the subchart (umbrella overrides
                          via <subchart-name>.labels are already coalesced in)
  4. extraLabels        - optional per-call additions

The app.kubernetes.io/part-of lane label is omitted for "shared" resources
(see componentName): a resource consumed by several lanes belongs to none.

Usage:
    labels:
      {{- include "krypton-lib-slim.labels" (dict "ctx" .) | nindent 4 }}
      {{- include "krypton-lib-slim.labels" (dict "ctx" . "extraLabels" (dict "tier" "web")) | nindent 4 }}
*/}}
{{- define "krypton-lib-slim.labels" -}}
{{- $ctx := .ctx -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $labels := dict
      "helm.sh/chart"                (include "krypton-lib-slim.chart" .)
      "app.kubernetes.io/name"       $ctx.Chart.Name
      "app.kubernetes.io/instance"   $ctx.Release.Name
      "app.kubernetes.io/managed-by" $ctx.Release.Service
-}}
{{- if not .shared -}}
{{- $_ := set $labels "app.kubernetes.io/part-of" (include "krypton-lib-slim.partOf" .) -}}
{{- end -}}
{{- with $ctx.Chart.AppVersion -}}
{{- $_ := set $labels "app.kubernetes.io/version" (. | toString) -}}
{{- end -}}
{{- $labels = mergeOverwrite $labels
      (deepCopy ($global.labels | default dict))
      (deepCopy ($ctx.Values.labels | default dict))
      (deepCopy (.extraLabels | default dict))
-}}
{{- toYaml $labels -}}
{{- end }}

{{/*
Selector labels - the immutable identity subset of the labels above, for
Deployment / Service / PDB / NetworkPolicy selectors. Never add mutable
values (lane, chart, version, custom labels) here: a Deployment's selector
cannot be changed after creation.

Usage:
    selector:
      matchLabels:
        {{- include "krypton-lib-slim.selectorLabels" (dict "ctx" .) | nindent 8 }}
*/}}
{{- define "krypton-lib-slim.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end }}


{{/* --------------------------------------------------------------------------
     ArgoCD sync waves & sync options
     -------------------------------------------------------------------------- */}}

{{/*
Resolve the ArgoCD sync wave for a component - returned as a string, or ""
when no wave is configured anywhere (the annotation is then omitted).

Lookup precedence (first hit wins):
  1. .Values.syncWaves.<component> of the calling subchart. Helm has already
     coalesced the umbrella's <subchart-name>.syncWaves.<component> override
     into this map, so "umbrella beats subchart default" comes for free.
  2. .Values.global.syncWaves.<component> - platform-wide defaults.

hasKey (not truthiness) is used so wave "0" and negative waves resolve too.
Waves are resolved per component TYPE: all instances of a type (every
ConfigMap, every VaultStaticSecret) share one wave.

Cross-subchart ordering: .Values.syncWaveOffset (per subchart, steered from
the umbrella; default 0) is added to every resolved wave, shifting the
subchart's WHOLE band relative to its siblings while preserving its
internal order. With a non-zero offset, components without a configured
wave - implicitly wave 0 in ArgoCD - are annotated with the bare offset, so
they move with the block instead of escaping to wave 0. Keep component
waves inside -9..9 and use offset steps of 10, then bands never overlap.

Usage (normally called for you by krypton-lib-slim.annotations):
    {{ include "krypton-lib-slim.syncWave" (dict "ctx" . "component" "route") }}
*/}}
{{- define "krypton-lib-slim.syncWave" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.syncWave: 'component' is required" .component -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $localWaves := $ctx.Values.syncWaves | default dict -}}
{{- $globalWaves := $global.syncWaves | default dict -}}
{{- $wave := "" -}}
{{- if hasKey $localWaves $component -}}
{{- $wave = get $localWaves $component | toString -}}
{{- else if hasKey $globalWaves $component -}}
{{- $wave = get $globalWaves $component | toString -}}
{{- end -}}
{{- $offset := $ctx.Values.syncWaveOffset | default 0 | int -}}
{{- if $wave -}}
{{- add (int $wave) $offset -}}
{{- else if ne $offset 0 -}}
{{- $offset -}}
{{- end -}}
{{- end }}

{{/*
Resolve the ArgoCD per-resource sync options for a component - returned as
the comma-joined value of the argocd.argoproj.io/sync-options annotation,
or "" when nothing is configured (the annotation is then omitted).

Any ArgoCD resource-level sync option can be listed, e.g.

    syncOptions:
      vaultStaticSecret: ["Prune=false"]              # survives app-level pruning
      route: ["Prune=false", "Delete=false"]          # also survives app deletion
      job: ["Replace=true"]                           # recreate instead of patch
      podMonitor: ["SkipDryRunOnMissingResource=true"]  # CRD not installed yet
      deployment: []                                  # explicitly nothing (overrides an inherited list)

A comma-separated string ("Prune=false,Delete=false") is accepted as well.

Lookup precedence per component, first hit wins (same chain as syncWave):
  1. .Values.syncOptions.<component> of the calling subchart (already
     contains umbrella overrides from <subchart-name>.syncOptions.<component>)
  2. .Values.global.syncOptions.<component> - platform-wide defaults

The lists do NOT merge across the two levels - the first hit replaces the
other, so a subchart can switch an inherited protection off with [].

Usage (normally called for you by krypton-lib-slim.annotations):
    {{ include "krypton-lib-slim.syncOptions" (dict "ctx" . "component" "route") }}
*/}}
{{- define "krypton-lib-slim.syncOptions" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.syncOptions: 'component' is required" .component -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $localOptions := $ctx.Values.syncOptions | default dict -}}
{{- $globalOptions := $global.syncOptions | default dict -}}
{{- $options := list -}}
{{- if hasKey $localOptions $component -}}
{{- $options = get $localOptions $component -}}
{{- else if hasKey $globalOptions $component -}}
{{- $options = get $globalOptions $component -}}
{{- end -}}
{{- if kindIs "slice" $options -}}
{{- range $o := $options -}}
{{- if not (kindIs "string" $o) -}}
{{- fail (printf "krypton-lib-slim: syncOptions.%s entries must be strings like \"Prune=false\", got %s (chart %q)" $component (kindOf $o) $ctx.Chart.Name) -}}
{{- end -}}
{{- end -}}
{{- $options | join "," -}}
{{- else if kindIs "string" $options -}}
{{- $options -}}
{{- else if not (kindIs "invalid" $options) -}}
{{- fail (printf "krypton-lib-slim: syncOptions.%s must be a list of ArgoCD sync options (e.g. [Prune=false]) or a comma-separated string, got %s (chart %q)" $component (kindOf $options) $ctx.Chart.Name) -}}
{{- end -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Annotations
     -------------------------------------------------------------------------- */}}

{{/*
The merged annotation block for a component.

One flat dict is built with mergeOverwrite; later sources overwrite earlier
ones on key collisions:

  1. chart-generated standard annotations (<labelDomain>/source-chart)
  2. global.annotations   - static annotations from the umbrella
  3. .Values.annotations  - custom annotations of the subchart (umbrella
                            overrides via <subchart-name>.annotations are
                            already coalesced in)
  4. .Values.jenkins.annotations
                          - CI-injected annotations (build number, commit,
                            job URL, ...), set per subchart from the umbrella
                            as <subchart-name>.jenkins.annotations, typically
                            via ArgoCD helm parameters. Only merged when the
                            block exists; values are stringified so a
                            numeric build id from --set stays a valid
                            annotation value.
  5. extraAnnotations     - optional per-call additions
  6. argocd.argoproj.io/sync-wave     - resolved via krypton-lib-slim.syncWave
  7. argocd.argoproj.io/sync-options  - resolved via krypton-lib-slim.syncOptions

The two ArgoCD annotations are applied LAST, so a configured wave or sync
option can never be shadowed; each is omitted entirely when unconfigured.

The dict passes through toYaml at the end, which quotes numeric strings -
annotation values therefore always reach the API server as strings, as
Kubernetes requires.

Usage:
    annotations:
      {{- include "krypton-lib-slim.annotations" (dict "ctx" . "component" "deployment") | nindent 4 }}

    with ad-hoc extras:
      {{- include "krypton-lib-slim.annotations" (dict "ctx" . "component" "route" "extraAnnotations" (dict "haproxy.router.openshift.io/timeout" "30s")) | nindent 4 }}
*/}}
{{- define "krypton-lib-slim.annotations" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.annotations: 'component' is required" .component -}}
{{- include "krypton-lib-slim.validateComponentConfig" (dict "ctx" $ctx) -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $domain := include "krypton-lib-slim.labelDomain" . -}}
{{- $standard := dict
      (printf "%s/source-chart" $domain) (include "krypton-lib-slim.chart" .)
-}}
{{- /* jenkins.annotations is optional: absent block -> nothing is merged */ -}}
{{- $jenkinsAnnotations := dict -}}
{{- with $ctx.Values.jenkins -}}
{{- if kindIs "map" . -}}
{{- range $k, $v := .annotations | default dict -}}
{{- $_ := set $jenkinsAnnotations $k (toString $v) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $annotations := mergeOverwrite (dict)
      $standard
      (deepCopy ($global.annotations | default dict))
      (deepCopy ($ctx.Values.annotations | default dict))
      $jenkinsAnnotations
      (deepCopy (.extraAnnotations | default dict))
-}}
{{- $wave := include "krypton-lib-slim.syncWave" (dict "ctx" $ctx "component" $component) -}}
{{- if $wave -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-wave" $wave -}}
{{- end -}}
{{- $syncOptions := include "krypton-lib-slim.syncOptions" (dict "ctx" $ctx "component" $component) -}}
{{- if $syncOptions -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-options" $syncOptions -}}
{{- end -}}
{{- toYaml $annotations -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Convenience
     -------------------------------------------------------------------------- */}}

{{/*
Complete metadata block - name, labels and annotations - in one include.
Accepts every argument of the granular helpers (component, instance,
extraLabels, extraAnnotations).

Usage:
    metadata:
      {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
      {{- include "krypton-lib-slim.metadata" (dict "ctx" $ "component" "configMap" "instance" $name) | nindent 2 }}
*/}}
{{- define "krypton-lib-slim.metadata" -}}
name: {{ include "krypton-lib-slim.componentName" . }}
labels:
  {{- include "krypton-lib-slim.labels" . | nindent 2 }}
annotations:
  {{- include "krypton-lib-slim.annotations" . | nindent 2 }}
{{- end }}
