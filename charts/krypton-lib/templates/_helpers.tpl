{{/* ==========================================================================
     krypton-lib - shared helpers for all Krypton subcharts
     ==========================================================================

     Call convention: every helper takes ONE argument, a dict built at the
     call site:

         {{ include "krypton-lib.<helper>" (dict "ctx" . "component" "<type>") }}

       ctx        (required) the caller's root context (`.` inside a subchart
                  template). Through it the helpers see the *subchart's*
                  coalesced .Values (subchart defaults + umbrella overrides +
                  global), its .Chart and the .Release.
       component  the component type of the manifest, e.g. "deployment",
                  "configmap", "route", "vaultStaticSecret". Drives the name
                  suffix and the sync-wave lookup. camelCase keys are
                  kebab-cased automatically wherever they end up in a
                  DNS-1123 name or label.
       instance   (optional) distinguishes multiple resources of the SAME
                  component type within one subchart (e.g. one
                  VaultStaticSecret per vault path); appended to the
                  resource name as an extra kebab-cased suffix.
       extra      (optional, krypton-lib.annotations only) dict of ad-hoc
                  annotations merged in with high precedence.

     Helm loads the templates of every chart in the dependency tree into one
     shared namespace, so these templates are callable from every subchart
     that sits next to krypton-lib underneath the umbrella - and from any
     chart that vendors krypton-lib through its own dependencies.
     ========================================================================== */}}


{{/* --------------------------------------------------------------------------
     Lane
     -------------------------------------------------------------------------- */}}

{{/*
The lane (deployment environment) of this umbrella instance, e.g. "release"
or "test". Fails the render loudly when the umbrella forgot to set it.
*/}}
{{- define "krypton-lib.laneName" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- required "krypton-lib: global.laneName is not set. Define it in the umbrella values.yaml (e.g. laneName: release)." $global.laneName -}}
{{- end }}

{{/*
Domain prefix for all platform-generated label and annotation keys:
<domain>/lane, <domain>/component, <domain>/source-chart. Configurable via
global.labelDomain so the scaffold can be reused for other platforms without
touching the library; defaults to krypton.io.
*/}}
{{- define "krypton-lib.labelDomain" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $global.labelDomain | default "krypton.io" -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Component catalog
     -------------------------------------------------------------------------- */}}

{{/*
Catalog of component types known to the platform - the single source of
truth for what may be passed as a "component" argument and what may appear
as a key under syncWaves / syncPrune.

Configuring a catalogued type that a subchart does not (yet) render is
allowed and simply has no effect - manifests pull their own settings, so
waves/prune flags can be staged ahead of the manifest. An uncatalogued key
fails the render instead of being silently ignored.

Extend this list - one line, no schema edits - when a genuinely new kind
enters the platform. Keep entries camelCase (kebab-cased automatically in
resource names); "configmap" is grandfathered lowercase.
*/}}
{{- define "krypton-lib.componentCatalog" -}}
buildConfig,clusterRole,clusterRoleBinding,configmap,cronJob,daemonSet,deployment,horizontalPodAutoscaler,imageStream,ingress,job,networkPolicy,persistentVolumeClaim,podDisruptionBudget,podMonitor,prometheusRule,role,roleBinding,route,secret,service,serviceAccount,serviceMonitor,statefulSet,vaultAuth,vaultConnection,vaultDynamicSecret,vaultStaticSecret
{{- end }}

{{/*
Fails the render when a component string is not in the catalog.
  ctx        caller context (for the chart name in the error message)
  component  the string to check
  origin     optional, names the source in the error (e.g. "syncWaves key")
*/}}
{{- define "krypton-lib.assertComponent" -}}
{{- $catalog := splitList "," (include "krypton-lib.componentCatalog" .) -}}
{{- if not (has .component $catalog) -}}
{{- fail (printf "krypton-lib: unknown component type %q (chart %q, %s). Known types: %s. Genuinely new kinds are added to krypton-lib.componentCatalog in krypton-lib/templates/_helpers.tpl." .component .ctx.Chart.Name (.origin | default "component argument") (include "krypton-lib.componentCatalog" .)) -}}
{{- end -}}
{{- end }}

{{/*
Validates every component key configured under syncWaves / syncPrune - both
subchart-level and global - against the catalog. Called from
krypton-lib.annotations, so it runs for every rendered manifest: an unknown
key can never be dropped silently, while catalogued-but-unrendered keys are
tolerated by design (pre-staged configuration).
*/}}
{{- define "krypton-lib.validateComponentConfig" -}}
{{- $ctx := .ctx -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- range $k, $_ := $ctx.Values.syncWaves | default dict -}}
{{- include "krypton-lib.assertComponent" (dict "ctx" $ctx "component" $k "origin" "syncWaves key") -}}
{{- end -}}
{{- range $k, $_ := $global.syncWaves | default dict -}}
{{- include "krypton-lib.assertComponent" (dict "ctx" $ctx "component" $k "origin" "global.syncWaves key") -}}
{{- end -}}
{{- range $k, $_ := $ctx.Values.syncPrune | default dict -}}
{{- include "krypton-lib.assertComponent" (dict "ctx" $ctx "component" $k "origin" "syncPrune key") -}}
{{- end -}}
{{- range $k, $_ := $global.syncPrune | default dict -}}
{{- include "krypton-lib.assertComponent" (dict "ctx" $ctx "component" $k "origin" "global.syncPrune key") -}}
{{- end -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Naming
     -------------------------------------------------------------------------- */}}

{{/*
helm.sh/chart label value: <chart-name>-<chart-version>.
*/}}
{{- define "krypton-lib.chart" -}}
{{- printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
The one sanctioned resource-name format:

    <subchart-name>-<global-lane-name>-<component-type>
    e.g. krypton-banking-release-deployment

  subchart-name   dynamic, from .Chart.Name of the calling subchart
  lane-name       from the umbrella's global.laneName
  component-type  passed by the caller; camelCase is normalised to kebab-case
                  ("vaultStaticSecret" -> "vault-static-secret") so the name
                  stays a valid DNS-1123 label

An optional "instance" is appended kebab-cased as one more suffix when a
subchart renders several resources of the same component type:
    krypton-banking-release-vault-static-secret-database

Truncated to 63 characters (the Kubernetes name limit for most resources).

Usage:
    name: {{ include "krypton-lib.componentName" (dict "ctx" . "component" "deployment") }}
    name: {{ include "krypton-lib.componentName" (dict "ctx" . "component" "vaultStaticSecret" "instance" "database") }}
*/}}
{{- define "krypton-lib.componentName" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib.componentName: 'component' is required" .component -}}
{{- include "krypton-lib.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- $lane := include "krypton-lib.laneName" . -}}
{{- $name := printf "%s-%s-%s" $ctx.Chart.Name $lane (kebabcase $component) -}}
{{- with .instance -}}
{{- $name = printf "%s-%s" $name (kebabcase .) -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Images, service accounts & templated values
     -------------------------------------------------------------------------- */}}

{{/*
Container image reference: <registry>/<repository>{:tag|@digest}.

  registry  global.imageRegistry when set - ONE umbrella key repoints every
            subchart at a per-lane proxy / air-gapped registry - otherwise
            the subchart's image.registry; empty renders no registry prefix.
  tag       image.tag, falling back to the subchart's Chart.AppVersion.
            image.digest takes precedence over the tag when set.

Usage:
    image: "{{ include "krypton-lib.image" (dict "ctx" .) }}"
    (pass "image" to use a different image block than .Values.image)
*/}}
{{- define "krypton-lib.image" -}}
{{- $ctx := .ctx -}}
{{- $image := .image | default $ctx.Values.image -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $registry := $global.imageRegistry | default $image.registry | default "" -}}
{{- $ref := required "krypton-lib.image: image.repository is required" $image.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $ref -}}
{{- end -}}
{{- if $image.digest -}}
{{- printf "%s@%s" $ref $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref ($image.tag | default $ctx.Chart.AppVersion | toString) -}}
{{- end -}}
{{- end }}

{{/*
Name of the ServiceAccount the workload runs as:

  serviceAccount.create=true  -> serviceAccount.name, defaulting to the
                                 platform name (componentName of type
                                 serviceAccount, e.g.
                                 krypton-banking-release-service-account)
  serviceAccount.create=false -> serviceAccount.name, defaulting to "default"
                                 (reference an existing SA)

Bind VaultAuth Kubernetes roles against exactly this name.
*/}}
{{- define "krypton-lib.serviceAccountName" -}}
{{- $ctx := .ctx -}}
{{- $sa := $ctx.Values.serviceAccount | default dict -}}
{{- if $sa.create -}}
{{- $sa.name | default (include "krypton-lib.componentName" (dict "ctx" $ctx "component" "serviceAccount")) -}}
{{- else -}}
{{- $sa.name | default "default" -}}
{{- end -}}
{{- end }}

{{/*
Renders a string value that may contain Go template syntax against the
caller's root context - for lane-aware values such as
vault.path: "krypton/{{ .Values.global.laneName }}/banking" or templated
Route hosts. Non-string values pass through as YAML.

Usage:
    path: {{ include "krypton-lib.tplValue" (dict "ctx" . "value" .Values.vault.path) }}
*/}}
{{- define "krypton-lib.tplValue" -}}
{{- if typeIs "string" .value -}}
{{- tpl .value .ctx -}}
{{- else -}}
{{- .value | toYaml -}}
{{- end -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Labels
     -------------------------------------------------------------------------- */}}

{{/*
Standard labels merged with the umbrella's static labels.

Merge order (later wins on key collisions):
  1. chart-generated standard labels (app.kubernetes.io/*, helm.sh/chart, lane)
  2. global.labels                  - static platform labels from the umbrella
  3. app.kubernetes.io/component    - when 'component' was passed

Usage:
    labels:
      {{- include "krypton-lib.labels" (dict "ctx" . "component" "deployment") | nindent 4 }}
*/}}
{{- define "krypton-lib.labels" -}}
{{- $ctx := .ctx -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $domain := include "krypton-lib.labelDomain" . -}}
{{- $labels := dict
      "helm.sh/chart"                (include "krypton-lib.chart" .)
      "app.kubernetes.io/name"       $ctx.Chart.Name
      "app.kubernetes.io/instance"   $ctx.Release.Name
      "app.kubernetes.io/managed-by" $ctx.Release.Service
      (printf "%s/lane" $domain)     (include "krypton-lib.laneName" .)
-}}
{{- with $ctx.Chart.AppVersion -}}
{{- $_ := set $labels "app.kubernetes.io/version" (. | toString) -}}
{{- end -}}
{{- $labels = mergeOverwrite $labels (deepCopy ($global.labels | default dict)) -}}
{{- with .component -}}
{{- $_ := set $labels "app.kubernetes.io/component" (kebabcase .) -}}
{{- end -}}
{{- toYaml $labels -}}
{{- end }}

{{/*
Selector labels - the immutable identity subset used in Deployment and
Service selectors. Never add mutable values (lane, chart, version) here:
a Deployment's selector cannot be changed after creation.

Usage:
    selector:
      matchLabels:
        {{- include "krypton-lib.selectorLabels" (dict "ctx" .) | nindent 8 }}
*/}}
{{- define "krypton-lib.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end }}


{{/* --------------------------------------------------------------------------
     Annotations & ArgoCD sync waves
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

Cross-subchart ordering: .Values.syncWaveOffset (per subchart, steered from
the umbrella; default 0) is added to every resolved wave, shifting the
subchart's WHOLE band relative to its siblings while preserving its
internal order. With a non-zero offset, components without a configured
wave - implicitly wave 0 in ArgoCD - are annotated with the bare offset, so
they move with the block instead of escaping to wave 0. Keep component
waves inside -9..9 and use offset steps of 10, then bands never overlap.

Usage (normally called for you by krypton-lib.annotations):
    {{ include "krypton-lib.syncWave" (dict "ctx" . "component" "route") }}
*/}}
{{- define "krypton-lib.syncWave" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib.syncWave: 'component' is required" .component -}}
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
the comma-joined value for the argocd.argoproj.io/sync-options annotation,
or "" when nothing is configured (the annotation is then omitted).

The only steered option so far is prune protection, via syncPrune values:

    syncPrune:
      <component>: false    ->  Prune=false: the resource survives app-level
                                pruning (manifest removed from git, subchart
                                disabled, ...) and must be deleted manually
      <component>: true     ->  no option: normal app-level prune behaviour
                                (useful to override an inherited false)

Lookup precedence per component, first hit wins (same chain as syncWave):
  1. .Values.syncPrune.<component> of the calling subchart (already contains
     umbrella overrides from <subchart-name>.syncPrune.<component>)
  2. .Values.global.syncPrune.<component> - platform-wide defaults

The comparison goes through toString, so a quoted "false" in values behaves
like the boolean. Further options (Delete=false, Replace=true, ...) can be
appended to $options here later without touching any manifest.

Usage (normally called for you by krypton-lib.annotations):
    {{ include "krypton-lib.syncOptions" (dict "ctx" . "component" "route") }}
*/}}
{{- define "krypton-lib.syncOptions" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib.syncOptions: 'component' is required" .component -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $localPrune := $ctx.Values.syncPrune | default dict -}}
{{- $globalPrune := $global.syncPrune | default dict -}}
{{- $options := list -}}
{{- if hasKey $localPrune $component -}}
{{- if eq ((get $localPrune $component) | toString) "false" -}}
{{- $options = append $options "Prune=false" -}}
{{- end -}}
{{- else if hasKey $globalPrune $component -}}
{{- if eq ((get $globalPrune $component) | toString) "false" -}}
{{- $options = append $options "Prune=false" -}}
{{- end -}}
{{- end -}}
{{- join "," $options -}}
{{- end }}

{{/*
The merged annotation block for a component.

One flat dict is built with mergeOverwrite; later sources overwrite earlier
ones on key collisions:

  1. chart-generated standard annotations (<labelDomain>/component and
     <labelDomain>/source-chart)
  2. global.annotations              - static annotations from the umbrella
  3. extra                           - optional per-call additions
  4. argocd.argoproj.io/sync-wave    - resolved via krypton-lib.syncWave
  5. argocd.argoproj.io/sync-options - resolved via krypton-lib.syncOptions
     (per-component prune protection via syncPrune values)

The two ArgoCD annotations are applied LAST, so a configured wave or sync
option can never be shadowed; each is omitted entirely when unconfigured.

The dict passes through toYaml at the end, which quotes numeric strings -
annotation values therefore always reach the API server as strings, as
Kubernetes requires.

Usage:
    annotations:
      {{- include "krypton-lib.annotations" (dict "ctx" . "component" "deployment") | nindent 4 }}

    with ad-hoc extras:
      {{- include "krypton-lib.annotations" (dict "ctx" . "component" "deployment" "extra" (dict "checksum/config" $checksum)) | nindent 4 }}
*/}}
{{- define "krypton-lib.annotations" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib.annotations: 'component' is required" .component -}}
{{- include "krypton-lib.validateComponentConfig" (dict "ctx" $ctx) -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $domain := include "krypton-lib.labelDomain" . -}}
{{- $standard := dict
      (printf "%s/component" $domain)    (kebabcase $component)
      (printf "%s/source-chart" $domain) (include "krypton-lib.chart" .)
-}}
{{- $annotations := mergeOverwrite (dict)
      $standard
      (deepCopy ($global.annotations | default dict))
      (deepCopy (.extra | default dict))
-}}
{{- $wave := include "krypton-lib.syncWave" (dict "ctx" $ctx "component" $component) -}}
{{- if $wave -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-wave" $wave -}}
{{- end -}}
{{- $syncOptions := include "krypton-lib.syncOptions" (dict "ctx" $ctx "component" $component) -}}
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

Usage:
    metadata:
      {{- include "krypton-lib.metadata" (dict "ctx" . "component" "configmap") | nindent 2 }}
*/}}
{{- define "krypton-lib.metadata" -}}
name: {{ include "krypton-lib.componentName" . }}
labels:
  {{- include "krypton-lib.labels" . | nindent 2 }}
annotations:
  {{- include "krypton-lib.annotations" . | nindent 2 }}
{{- end }}
