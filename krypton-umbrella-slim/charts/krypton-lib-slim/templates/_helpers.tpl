{{/*
krypton-lib-slim - shared template helpers for Krypton subcharts.

This library generates resource metadata and Argo CD annotations. It also
provides Pod selector labels and validates names in resource maps. Workload
configuration, such as images, probes and volumes, stays in the subcharts.

Calling convention: pass one dictionary containing the helper's arguments.

    {{ include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") }}

  ctx              The calling subchart's root context. Pass . at the top
                   level of its template. Inside range or with, use a saved
                   root context or $ if it still refers to that root.
                   ctx provides .Values, .Chart and .Release. Helm has
                   already merged umbrella overrides into the subchart's
                   values and made global values available as .Values.global.

  component        Required by componentName, metadata, annotations and the
                   sync helpers. Identifies a type such as "deployment".
                   Each of these helpers validates it against the catalog.
                   Sync helpers use it to look up settings. It is not part of
                   the generated name.

  instance         Optional resource identifier used by componentName and
                   metadata. Appended to the name after normalization; use
                   it to distinguish resources of the same kind.

  shared           Optional flag for componentName, labels, metadata and
                   validateResourceNames. When true, naming omits the lane
                   and the labels helper omits app.kubernetes.io/part-of.
                   This flag does not coordinate ownership or creation.

  chart            Optional chart name for componentName and metadata.
                   Replaces ctx.Chart.Name in the resource name only; labels
                   and annotations still use the caller's context. Useful
                   when componentName references another chart's resource.

  extraLabels      Optional map for labels or metadata. Overrides other
                   custom labels, but cannot override reserved identity
                   labels. See the labels helper for the complete order.

  extraAnnotations
                   Optional annotation map for annotations or metadata.
                   See the annotations helper for the complete merge order.

  annotation       Optional "key=value" string for annotations or metadata.
                   Adds one annotation after extraAnnotations.

  annotationsFrom  Optional dotted path under ctx.Values for annotations or
                   metadata, for example "route.annotations". Reads a map
                   for this resource. See annotations for missing paths,
                   null values and invalid targets.

Helm loads named templates from the dependency tree into a shared template
namespace. Subcharts in this umbrella can therefore call the library's
helpers. To render a subchart on its own, first build its declared local
library dependency.

Values used by the library:
  global.laneName        Lane used in names and identity labels. Required
                         when a helper needs a lane; shared metadata omits it.
                         The umbrella schema separately requires this value.
  global.namePrefix      Optional prefix for resource names, including shared
                         resources; defaults to an empty string.
  global.partOfPrefix    Optional prefix for the lane label, not resource names.
  global.labelDomain     Domain of the source-chart annotation; defaults to
                         krypton.io.
  global.labels          Additional labels shared across subcharts.
  global.annotations     Additional resource annotations shared across subcharts.
  global.syncWaves       Default sync wave for each component type.
  global.syncOptions     Default sync options for each component type.
  labels, annotations   Additional metadata values for the calling subchart.
  syncWaves, syncOptions Overrides for the calling subchart, per component type.
  syncWaveOffset        Offset added to the subchart's waves; defaults to zero.

validateResourceNames also reads configMaps, secrets and vault.secrets.
*/}}


{{/* --------------------------------------------------------------------------
     Lane and label domain
     -------------------------------------------------------------------------- */}}

{{/*
Return global.laneName, for example "release" or "test". Rendering fails
with an explanatory error if the value is missing or empty.
*/}}
{{- define "krypton-lib-slim.laneName" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- required "krypton-lib-slim: global.laneName is not set. Define it in the umbrella values.yaml (e.g. laneName: release)." $global.laneName -}}
{{- end }}

{{/*
Return the app.kubernetes.io/part-of label value:
    [<global.partOfPrefix>-]<global.laneName>

For example, partOfPrefix "krypton" and laneName "release" produce
"krypton-release". With no prefix, the result is "release". This helper
does not change resource names and requires a lane through laneName.
The combined value must be a valid, nonempty Kubernetes label value of at
most 63 characters; otherwise rendering fails.
The prefix is configured explicitly because ctx.Chart describes the calling
subchart, not its parent umbrella.
*/}}
{{- define "krypton-lib-slim.partOf" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $value := include "krypton-lib-slim.laneName" . -}}
{{- with $global.partOfPrefix -}}{{- $value = printf "%s-%s" . $value -}}{{- end -}}
{{- if or (gt (len $value) 63) (not (regexMatch "^[a-zA-Z0-9]([a-zA-Z0-9_.-]*[a-zA-Z0-9])?$" $value)) -}}
{{- fail (printf "krypton-lib-slim.partOf: invalid label value %q (chart %q); global.partOfPrefix and global.laneName together must form a label of at most 63 characters, with alphanumeric ends and only letters, digits, '-', '_' or '.'" $value .ctx.Chart.Name) -}}
{{- end -}}
{{- $value -}}
{{- end }}

{{/*
Return global.namePrefix, or an empty string when unset.

componentName uses this prefix for both lane-specific and shared resource
names. For example, "acme" produces "acme-krypton-payments-release"
or "acme-krypton-shared-common". This setting changes names only; it does
not isolate Pod selectors or enforce uniqueness across releases.
*/}}
{{- define "krypton-lib-slim.namePrefix" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $global.namePrefix | default "" -}}
{{- end }}

{{/*
Return the domain for the generated <domain>/source-chart annotation.
Uses global.labelDomain, with "krypton.io" as the fallback. Custom keys in
label and annotation maps are unaffected by this setting.
*/}}
{{- define "krypton-lib-slim.labelDomain" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $global.labelDomain | default "krypton.io" -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Component catalog
     -------------------------------------------------------------------------- */}}

{{/*
Return the catalog of component-type keys used by this library.
The map values are resource abbreviations retained for documentation;
neither library appends them to resource names.

Helpers with a component argument validate it against this catalog.
validateComponentConfig checks keys in syncWaves and syncOptions when
called by annotations. A recognized type may be configured even when the
subchart does not render that type; the setting then has no effect.

Add new component types to both library catalogs so their accepted keys
remain consistent. Adding a catalog entry does not require a schema change;
new workload values may still require changes to the relevant schema.
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
Fail rendering if component is not a key in componentCatalog.

Arguments:
  ctx        Caller context; supplies the chart name for the error message.
  component  Component-type string to validate.
  origin     Optional description of the source, such as "syncWaves key".
*/}}
{{- define "krypton-lib-slim.assertComponent" -}}
{{- $catalog := fromYaml (include "krypton-lib-slim.componentCatalog" .) -}}
{{- if or (not (kindIs "string" .component)) (not (hasKey $catalog (.component | toString))) -}}
{{- fail (printf "krypton-lib-slim: unknown component type %q (chart %q, %s). Known types: %s. Genuinely new kinds are added to krypton-lib-slim.componentCatalog in krypton-lib-slim/templates/_helpers.tpl." .component .ctx.Chart.Name (.origin | default "component argument") (keys $catalog | sortAlpha | join ",")) -}}
{{- end -}}
{{- end }}

{{/*
Validate component keys in the calling subchart's syncWaves and syncOptions
maps and in their global equivalents. Known types are allowed even if the
subchart does not render resources of those types.

annotations calls this helper, including when invoked through metadata.
It does not check disabled charts or templates that never call it.
This helper checks catalog membership, not the types of configured values.
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
Return the helm.sh/chart label value as <chart-name>-<chart-version>.
Replace "+" with "_", truncate to 63 characters, and remove a trailing
hyphen if present.
*/}}
{{- define "krypton-lib-slim.chart" -}}
{{- printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Build a resource name using the following format:

    [<namePrefix>-]<chart>-<lane>[-<instance>]

  namePrefix  global.namePrefix; omitted when empty.
  chart       The chart argument, falling back to ctx.Chart.Name.
  lane        global.laneName; omitted when shared is true.
  instance    Optional suffix for resources of the same kind.

Examples with no name prefix:
    krypton-payments-release           Deployment, Service or ServiceAccount
    krypton-payments-release-database  VaultStaticSecret with instance "database"
    krypton-shared-common   Shared ConfigMap with instance "common"

component is required and validated, but does not affect the name. A
Deployment and a Service can use the same name because they have different
kinds. Two Secrets need different final names, including when one Secret
is created by a VaultStaticSecret controller.

Instance normalization inserts a hyphen between a lowercase letter or digit
and a following uppercase letter ("logLevel" becomes "log-level"), converts
the result to lowercase, and replaces characters outside [a-z0-9-] with
hyphens. The complete name must fit within 63 characters; longer names
fail rendering instead of being truncated. One trailing hyphen is removed
for compatibility. The result must contain only lowercase letters, digits
and hyphens, with an alphanumeric character at each end; otherwise rendering
fails. Normalization does not guarantee uniqueness. validateResourceNames
checks collisions in the resource maps supported by the example charts.

shared keeps namePrefix but omits the lane. Assign each shared resource to
one managing release or Application; this helper only computes its name.

For references across subcharts, pass the owning chart's name. Both sides
must use matching prefixes, instances and shared settings (and matching
lanes for lane-specific resources). For example:

    # In krypton-shared: create the ConfigMap.
    {{ include "krypton-lib-slim.componentName" (dict "ctx" . "component" "configMap" "instance" "common" "shared" true) }}
    # In a consuming subchart: reference the same ConfigMap.
    {{ include "krypton-lib-slim.componentName" (dict "ctx" . "chart" "krypton-shared" "component" "configMap" "instance" "common" "shared" true) }}

Both calls produce krypton-shared-common when namePrefix is empty.
Neither call verifies that the referenced resource exists.
*/}}
{{- define "krypton-lib-slim.componentName" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.componentName: 'component' is required" .component -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- $name := .chart | default $ctx.Chart.Name -}}
{{- with include "krypton-lib-slim.namePrefix" . -}}
{{- $name = printf "%s-%s" . $name -}}
{{- end -}}
{{- if not .shared -}}
{{- $name = printf "%s-%s" $name (include "krypton-lib-slim.laneName" .) -}}
{{- end -}}
{{- with .instance -}}
{{- $instance := regexReplaceAll "([a-z0-9])([A-Z])" (toString .) "${1}-${2}" | lower -}}
{{- $instance = regexReplaceAll "[^a-z0-9-]" $instance "-" -}}
{{- $name = printf "%s-%s" $name $instance -}}
{{- end -}}
{{- if gt (len $name) 63 -}}
{{- fail (printf "krypton-lib-slim.componentName: resource name %q exceeds 63 characters (chart %q); shorten namePrefix, chart, laneName or instance" $name $ctx.Chart.Name) -}}
{{- end -}}
{{- $name = trimSuffix "-" $name -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail (printf "krypton-lib-slim.componentName: invalid resource name %q (chart %q); use lowercase letters, digits and hyphens, with a letter or digit at each end" $name $ctx.Chart.Name) -}}
{{- end -}}
{{- $name -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Labels
     -------------------------------------------------------------------------- */}}

{{/*
Build resource or Pod labels from the following sources, in order:

  1. Generated standard labels, including helm.sh/chart and app.kubernetes.io/*.
  2. global.labels.
  3. ctx.Values.labels, including umbrella overrides.
  4. extraLabels from this call.

Later custom sources overwrite earlier values. After merging, the library
sets the reserved identity labels independently of any custom values:

    app.kubernetes.io/name       ctx.Chart.Name
    app.kubernetes.io/instance   ctx.Release.Name
    app.kubernetes.io/part-of    [<partOfPrefix>-]<laneName>

For shared resources, part-of is removed even if a custom map supplied it.
The other identity labels still identify the calling chart and release.
All final values are converted to strings before YAML serialization.

Usage:
    labels:
      {{- include "krypton-lib-slim.labels" (dict "ctx" .) | nindent 4 }}
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
{{- /* Apply reserved identity labels after merging custom labels. */ -}}
{{- $_ := set $labels "app.kubernetes.io/name" $ctx.Chart.Name -}}
{{- $_ := set $labels "app.kubernetes.io/instance" $ctx.Release.Name -}}
{{- if .shared -}}
{{- $_ := unset $labels "app.kubernetes.io/part-of" -}}
{{- else -}}
{{- $_ := set $labels "app.kubernetes.io/part-of" (include "krypton-lib-slim.partOf" .) -}}
{{- end -}}
{{- range $key, $value := $labels -}}
{{- $_ := set $labels $key (toString $value) -}}
{{- end -}}
{{- toYaml $labels -}}
{{- end }}

{{/*
Return the three identity labels used to select Pods:

    app.kubernetes.io/name       ctx.Chart.Name
    app.kubernetes.io/instance   ctx.Release.Name
    app.kubernetes.io/part-of    [<partOfPrefix>-]<laneName>

These values match labels when used for a lane-specific Pod template.
This helper always includes the lane and does not accept a shared mode.
The instance label identifies the Helm release; it is unrelated to the
instance argument used to distinguish resource names.

Use this stable subset for Deployment and Service selectors. Avoid chart
versions and other values that change during upgrades: a Deployment's
selector is immutable. Changing partOfPrefix requires planned recreation
of existing Deployments and may affect availability. Changing laneName
also changes resource names. All selector values are serialized as strings.
namePrefix does not affect these selectors.

Usage:
    selector:
      matchLabels:
        {{- include "krypton-lib-slim.selectorLabels" (dict "ctx" .) | nindent 8 }}
*/}}
{{- define "krypton-lib-slim.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name | toString | quote }}
app.kubernetes.io/instance: {{ .ctx.Release.Name | toString | quote }}
app.kubernetes.io/part-of: {{ include "krypton-lib-slim.partOf" . | quote }}
{{- end }}


{{/* --------------------------------------------------------------------------
     Argo CD sync waves and sync options
     -------------------------------------------------------------------------- */}}

{{/*
Internal helper: validate and normalize a sync wave or offset as a signed
64-bit decimal integer. Accept integer values or decimal strings; leading
zeros are decimal, never octal. Reject invalid input before conversion.
Arguments: value and origin (the setting's path for error messages).
*/}}
{{- define "krypton-lib-slim.syncInteger" -}}
{{- $text := toString .value -}}
{{- if not (regexMatch "^-?[0-9]+$" $text) -}}
{{- fail (printf "krypton-lib-slim: %s must be a decimal integer, got %q" .origin $text) -}}
{{- end -}}
{{- $negative := hasPrefix "-" $text -}}
{{- $digits := regexReplaceAll "^0+" (trimPrefix "-" $text) "" | default "0" -}}
{{- $limit := "9223372036854775807" -}}
{{- if $negative -}}{{- $limit = "9223372036854775808" -}}{{- end -}}
{{- if or (gt (len $digits) 19) (and (eq (len $digits) 19) (gt $digits $limit)) -}}
{{- fail (printf "krypton-lib-slim: %s is outside the signed 64-bit range, got %q" .origin $text) -}}
{{- end -}}
{{- if and $negative (ne $digits "0") -}}-{{- end -}}{{- $digits -}}
{{- end }}

{{/*
Resolve the sync wave for component and return it as text.

Lookup order (first configured key wins):
  1. ctx.Values.syncWaves.<component>, including umbrella overrides.
  2. ctx.Values.global.syncWaves.<component>.

The key's presence determines precedence, so an explicit zero overrides a
global value. Positive, zero and negative waves are supported. Waves and
offsets accept integers or decimal strings, including leading zeros ("08"
means 8). Each value and their sum must fit in the signed 64-bit range;
invalid values and overflow fail rendering. All instances
of a component type within the subchart use the same resolved wave.

Add ctx.Values.syncWaveOffset (default zero) to the resolved wave. If no
wave is configured, a nonzero offset is returned by itself. If neither a
wave nor a nonzero offset is configured, return an empty string.

Offsets preserve the relative order of a subchart's component waves. Choose
them using the actual ranges: local waves -9..9 need an offset difference
of at least 19 to avoid overlap. This calculation does not check resource
readiness or coordinate separate Argo CD Applications.

Called by annotations. Direct usage:
    {{ include "krypton-lib-slim.syncWave" (dict "ctx" . "component" "route") }}
*/}}
{{- define "krypton-lib-slim.syncWave" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.syncWave: 'component' is required" .component -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $localWaves := $ctx.Values.syncWaves | default dict -}}
{{- $globalWaves := $global.syncWaves | default dict -}}
{{- $wave := "" -}}
{{- if hasKey $localWaves $component -}}
{{- $wave = include "krypton-lib-slim.syncInteger" (dict "value" (get $localWaves $component) "origin" (printf "syncWaves.%s" $component)) -}}
{{- else if hasKey $globalWaves $component -}}
{{- $wave = include "krypton-lib-slim.syncInteger" (dict "value" (get $globalWaves $component) "origin" (printf "global.syncWaves.%s" $component)) -}}
{{- end -}}
{{- $offset := int64 0 -}}
{{- if hasKey $ctx.Values "syncWaveOffset" -}}
{{- $offset = include "krypton-lib-slim.syncInteger" (dict "value" $ctx.Values.syncWaveOffset "origin" "syncWaveOffset") | int64 -}}
{{- end -}}
{{- if or $wave (ne $offset (int64 0)) -}}
{{- $base := $wave | default "0" | int64 -}}
{{- $result := add $base $offset -}}
{{- if or (and (gt $offset (int64 0)) (lt $result $base)) (and (lt $offset (int64 0)) (gt $result $base)) -}}
{{- fail (printf "krypton-lib-slim.syncWave: wave plus syncWaveOffset is outside the signed 64-bit range (chart %q, component %q)" $ctx.Chart.Name $component) -}}
{{- end -}}
{{- $result -}}
{{- end -}}
{{- end }}

{{/*
Resolve resource-level Argo CD sync options for component.

Lookup order (first configured key wins):
  1. ctx.Values.syncOptions.<component>, including umbrella overrides.
  2. ctx.Values.global.syncOptions.<component>.

Accept a list of strings or a comma-separated string. Lists are joined
with commas; strings are returned as supplied. The local value replaces
the global value rather than merging with it. An empty list or string
therefore clears the inherited helper result. Null also produces an empty
result; unsupported value types cause rendering to fail.

Examples:
    syncOptions:
      vaultStaticSecret: ["Prune=false"]      # Protect during sync pruning.
      route: ["Prune=false", "Delete=false"]  # Also protect on app deletion.
      deployment: []                         # Clear inherited sync options.

The helper checks value types, not whether Argo CD recognizes or supports
each option. An empty result does not remove a raw sync-options annotation
supplied through an annotation map; see annotations.

Called by annotations. Direct usage:
    {{ include "krypton-lib-slim.syncOptions" (dict "ctx" . "component" "route") }}
*/}}
{{- define "krypton-lib-slim.syncOptions" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.syncOptions: 'component' is required" .component -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $component) -}}
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
Build the annotation map for one resource. Later sources overwrite earlier
values with the same key:

  1. Generated <labelDomain>/source-chart.
  2. global.annotations.
  3. ctx.Values.annotations, including umbrella overrides.
  4. extraAnnotations from this call.
  5. annotation from this call.
  6. annotationsFrom from this call.

extraAnnotations is a map supplied at the call site. annotation accepts one
"key=value" string, splits it at the first "=", and trims whitespace from
the key and value. An empty key or a string without "=" fails rendering.

annotationsFrom traverses a dotted path under ctx.Values, for example
"route.annotations". Missing keys, paths that cannot be traversed, and
null targets contribute nothing. A reachable, non-null target must be a
map; a scalar or list at the final path causes rendering to fail. Dots
separate path segments and cannot address literal dots in map keys.

Nonempty results from syncWave and syncOptions are applied after all maps.
They override the corresponding argocd.argoproj.io/sync-wave and
argocd.argoproj.io/sync-options entries. An empty helper result does not
remove an entry supplied by an earlier source. Prefer syncWaves and
syncOptions over directly setting those annotations.

Every final annotation value is converted to a string before YAML
serialization, including numbers and booleans supplied by helper callers.

Usage:
    annotations:
      {{- include "krypton-lib-slim.annotations" (dict "ctx" . "component" "deployment") | nindent 4 }}

    # An annotation map for one resource.
    {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "route" "extraAnnotations" (dict "haproxy.router.openshift.io/timeout" "30s")) | nindent 2 }}

    # A single annotation for one resource.
    {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "route" "annotation" "haproxy.router.openshift.io/timeout=300s") | nindent 2 }}

    # Inside range: read annotations for the current named Route.
    {{- include "krypton-lib-slim.metadata" (dict "ctx" $ "component" "route" "instance" $name "annotationsFrom" (printf "routes.%s.annotations" $name)) | nindent 2 }}
*/}}
{{- define "krypton-lib-slim.annotations" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib-slim.annotations: 'component' is required" .component -}}
{{- include "krypton-lib-slim.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- include "krypton-lib-slim.validateComponentConfig" (dict "ctx" $ctx) -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $domain := include "krypton-lib-slim.labelDomain" . -}}
{{- $standard := dict
      (printf "%s/source-chart" $domain) (include "krypton-lib-slim.chart" .)
-}}
{{- /* Parse one key=value annotation; preserve any later equals signs. */ -}}
{{- $single := dict -}}
{{- with .annotation -}}
{{- $kv := regexSplit "=" (toString .) 2 -}}
{{- if or (ne (len $kv) 2) (eq (index $kv 0 | trim) "") -}}
{{- fail (printf "krypton-lib-slim.annotations: 'annotation' must be a \"key=value\" string, got %q (chart %q)" (toString .) $ctx.Chart.Name) -}}
{{- end -}}
{{- $_ := set $single (index $kv 0 | trim) (index $kv 1 | trim) -}}
{{- end -}}
{{- /* Read a values path; validate a reachable, non-null target as a map. */ -}}
{{- $fromValues := dict -}}
{{- with .annotationsFrom -}}
{{- $node := $ctx.Values -}}
{{- $missing := false -}}
{{- range splitList "." (toString .) -}}
{{- if and (not $missing) (kindIs "map" $node) (hasKey $node .) -}}
{{- $node = index $node . -}}
{{- else -}}
{{- $missing = true -}}
{{- end -}}
{{- end -}}
{{- if and (not $missing) (not (kindIs "invalid" $node)) -}}
{{- if not (kindIs "map" $node) -}}
{{- fail (printf "krypton-lib-slim.annotations: annotationsFrom %q must point to a map of annotations, got %s (chart %q)" (toString .) (kindOf $node) $ctx.Chart.Name) -}}
{{- end -}}
{{- range $k, $v := $node -}}
{{- $_ := set $fromValues $k (toString $v) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $annotations := mergeOverwrite (dict)
      $standard
      (deepCopy ($global.annotations | default dict))
      (deepCopy ($ctx.Values.annotations | default dict))
      (deepCopy (.extraAnnotations | default dict))
      $single
      $fromValues
-}}
{{- $wave := include "krypton-lib-slim.syncWave" (dict "ctx" $ctx "component" $component) -}}
{{- if $wave -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-wave" $wave -}}
{{- end -}}
{{- $syncOptions := include "krypton-lib-slim.syncOptions" (dict "ctx" $ctx "component" $component) -}}
{{- if $syncOptions -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-options" $syncOptions -}}
{{- end -}}
{{- /* Convert every merged annotation value to a string. */ -}}
{{- range $key, $value := $annotations -}}
{{- $_ := set $annotations $key (toString $value) -}}
{{- end -}}
{{- toYaml $annotations -}}
{{- end }}


{{/* --------------------------------------------------------------------------
     Complete metadata
     -------------------------------------------------------------------------- */}}

{{/*
Return name, labels and annotations as the contents of a metadata block.
The caller supplies the metadata: key and indentation.

Pass ctx and component. Optional arguments are instance, shared, chart,
extraLabels, extraAnnotations, annotation and annotationsFrom. The same argument
dictionary is forwarded to componentName, labels and annotations.
chart affects the name only; metadata labels still describe ctx.Chart.

Usage:
    metadata:
      {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "configMap") | nindent 2 }}
*/}}
{{- define "krypton-lib-slim.metadata" -}}
name: {{ include "krypton-lib-slim.componentName" . }}
labels:
  {{- include "krypton-lib-slim.labels" . | nindent 2 }}
annotations:
  {{- include "krypton-lib-slim.annotations" . | nindent 2 }}
{{- end }}

{{/*
Reject duplicate final names within the calling subchart's resource maps.
Uses componentName, so comparisons include instance normalization and validated names.

Arguments: ctx and optional shared. Call this helper explicitly, for example
from templates/validate.yaml, using the same shared mode as the resources.
It produces no output on success and fails rendering on a collision.

Two groups are checked independently:
  - configMaps: ConfigMap names must be unique within this map.
  - secrets and vault.secrets: plain Secrets and Vault destination Secrets
    must have unique names across both maps and within each map.

A ConfigMap and a Secret may share a name. The internal component argument
is "secret" for both groups because componentName does not include the
component type in its output. The groups, rather than this argument,
determine which names are compared.

This helper assumes the map key is the resource's instance suffix. It does
not inspect arbitrary templates, check other charts or releases, query the
cluster, or perform complete Kubernetes-name validation.
*/}}
{{- define "krypton-lib-slim.validateResourceNames" -}}
{{- $args := . -}}
{{- $values := .ctx.Values -}}
{{- $vault := ($values.vault | default dict).secrets | default dict -}}
{{- range $group := list (dict "configMaps" ($values.configMaps | default dict)) (dict "secrets" ($values.secrets | default dict) "vault.secrets" $vault) -}}
{{- $seen := dict -}}
{{- range $source, $entries := $group -}}
{{- range $key, $_ := $entries -}}
{{- $name := include "krypton-lib-slim.componentName" (dict "ctx" $args.ctx "component" "secret" "instance" $key "shared" $args.shared) -}}
{{- $origin := printf "%s.%s" $source $key -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "krypton-lib-slim: %s and %s produce the same resource name %q (chart %q); use distinct names after normalization" (get $seen $name) $origin $name $args.ctx.Chart.Name) -}}
{{- end -}}
{{- $_ := set $seen $name $origin -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
