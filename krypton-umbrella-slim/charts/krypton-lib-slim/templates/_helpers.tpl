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
                         "vaultStaticSecret". Drives the name suffix (the
                         type's catalogued Kubernetes shortname, configMap ->
                         cm) and the sync-wave / sync-options lookup.
       instance          (optional) identifier that distinguishes several
                         resources of the SAME component type within one
                         subchart - two ConfigMaps, three Secrets, one
                         VaultStaticSecret per Vault path. Appended to the
                         resource name as one more kebab-cased suffix.
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
Domain prefix for all platform-generated label and annotation keys:
<domain>/lane, <domain>/source-chart. Configurable via global.labelDomain so
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
as a key under syncWaves / syncOptions - and of the Kubernetes shortname
(kubectl api-resources) each type is abbreviated to in resource names:
configMap -> cm, deployment -> deploy. An empty shortname means the kind
has none upstream (Route, Secret, the VSO kinds, ...); those names fall
back to the kebab-cased type.

Configuring a catalogued type that a subchart does not (yet) render is
allowed and simply has no effect - manifests pull their own settings, so
waves / sync options can be staged ahead of the manifest. An uncatalogued
key fails the render instead of being silently ignored.

Extend this map - one camelCase line, no schema edits - when a genuinely
new kind enters the platform. Keep it identical to the full krypton-lib
catalog so both variants produce the same names.
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

    <subchart-name>-<global-lane-name>-<component-shortname>[-<instance>]
    e.g. krypton-payments-release-deploy
         krypton-payments-release-cm-logging
         krypton-payments-release-vault-static-secret-database

  subchart-name        dynamic, from .Chart.Name of the calling subchart
  lane-name            from the umbrella's global.laneName
  component-shortname  the Kubernetes shortname the catalog maps the
                       caller's component type to ("configMap" -> "cm");
                       types without one fall back to the kebab-cased type
                       ("vaultStaticSecret" -> "vault-static-secret"), so
                       the name always stays a valid DNS-1123 label
  instance             optional, kebab-cased; the identifier for several
                       resources of the same type in one subchart

Truncated to 63 characters (the Kubernetes name limit for most resources).

Usage:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "component" "deployment") }}
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "component" "configMap" "instance" "logging") }}
*/}}
{{- define "krypton-lib-slim.componentName" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.componentName: 'component' is required" .component -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- $lane := include "krypton-lib-slim.laneName" . -}}
{{- $short := get (fromYaml (include "krypton-lib-slim.componentCatalog" .)) $component | default (kebabcase $component) -}}
{{- $name := printf "%s-%s-%s" $ctx.Chart.Name $lane $short -}}
{{- with .instance -}}
{{- $name = printf "%s-%s" $name (kebabcase (toString .)) -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Labels
     -------------------------------------------------------------------------- */}}

{{/*
The merged label set for a resource.

Merge order (later wins on key collisions):
  1. chart-generated standard labels (app.kubernetes.io/*, helm.sh/chart,
     <labelDomain>/lane)
  2. global.labels      - static platform labels from the umbrella
  3. .Values.labels     - custom labels of the subchart (umbrella overrides
                          via <subchart-name>.labels are already coalesced in)
  4. extraLabels        - optional per-call additions

Usage:
    labels:
      {{- include "krypton-lib-slim.labels" (dict "ctx" .) | nindent 4 }}
      {{- include "krypton-lib-slim.labels" (dict "ctx" . "extraLabels" (dict "tier" "web")) | nindent 4 }}
*/}}
{{- define "krypton-lib-slim.labels" -}}
{{- $ctx := .ctx -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $domain := include "krypton-lib-slim.labelDomain" . -}}
{{- $labels := dict
      "helm.sh/chart"                (include "krypton-lib-slim.chart" .)
      "app.kubernetes.io/name"       $ctx.Chart.Name
      "app.kubernetes.io/instance"   $ctx.Release.Name
      "app.kubernetes.io/managed-by" $ctx.Release.Service
      (printf "%s/lane" $domain)     (include "krypton-lib-slim.laneName" .)
-}}
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
