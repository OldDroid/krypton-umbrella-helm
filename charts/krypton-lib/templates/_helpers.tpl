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
                  "configMap", "route", "vaultStaticSecret". Validated
                  against the component catalog and drives the sync-wave /
                  prune lookup; it is NOT part of the name.
       instance   (optional) distinguishes multiple resources of the SAME
                  kind within one subchart (e.g. one VaultStaticSecret per
                  vault path); appended to the resource name, normalised to
                  a DNS-1123 label.
       shared     (optional) true marks the resource as lane-independent:
                  the name omits the lane segment
                  (<subchart-name>[-<instance>]) and the
                  app.kubernetes.io/part-of lane label is not stamped. For
                  ConfigMaps / Secrets that several lane deployments
                  consume, so they are created once instead of once per
                  lane.
       chart      (optional, krypton-lib.componentName only) name of the
                  subchart that OWNS the resource, for templates that
                  reference a resource rendered by another subchart - e.g.
                  "krypton-shared" for the lane-independent ConfigMaps /
                  Secrets. Defaults to the caller's own .Chart.Name.
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
Value of the app.kubernetes.io/part-of lane label: the lane name, prefixed
with global.partOfPrefix when set (e.g. partOfPrefix "krypton-umbrella"
gives krypton-umbrella-release instead of release). The prefix is a value
because a subchart's .Chart is its own chart - the umbrella's name is not
reachable from inside the library.
*/}}
{{- define "krypton-lib.partOf" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $lane := include "krypton-lib.laneName" . -}}
{{- with $global.partOfPrefix -}}{{- printf "%s-%s" . $lane -}}{{- else -}}{{- $lane -}}{{- end -}}
{{- end }}

{{/*
Optional prefix for every resource name, from global.namePrefix: "" (the
default) keeps <subchart-name>-<laneName>[-<instance>], "acme" renders
acme-<subchart-name>-<laneName>[-<instance>]. Applies to shared resources
too (acme-krypton-shared-common), so an umbrella that carries a prefix
keeps its lane-specific and its lane-independent resources apart from a
second, unprefixed (or differently prefixed) umbrella in the same
namespace. Consumed by krypton-lib.componentName only.
*/}}
{{- define "krypton-lib.namePrefix" -}}
{{- $global := .ctx.Values.global | default dict -}}
{{- $global.namePrefix | default "" -}}
{{- end }}

{{/*
Domain prefix for the platform-generated annotation key
<domain>/source-chart (the lane itself is carried by the standard
app.kubernetes.io/part-of label). Configurable via global.labelDomain so
the scaffold can be reused for other platforms without touching the
library; defaults to krypton.io.
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
as a key under syncWaves / syncPrune. The values are the Kubernetes
shortnames (kubectl api-resources) of the kinds; the naming scheme
(<subchart>-<lane>[-<instance>]) does not use them, they are kept as
documentation and so that both library variants carry exactly the same
catalog.

Configuring a catalogued type that a subchart does not (yet) render is
allowed and simply has no effect - manifests pull their own settings, so
waves/prune flags can be staged ahead of the manifest. An uncatalogued key
fails the render instead of being silently ignored.

Extend this map - one camelCase line, no schema edits - when a genuinely
new kind enters the platform.
*/}}
{{- define "krypton-lib.componentCatalog" -}}
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
{{- define "krypton-lib.assertComponent" -}}
{{- $catalog := fromYaml (include "krypton-lib.componentCatalog" .) -}}
{{- if not (hasKey $catalog .component) -}}
{{- fail (printf "krypton-lib: unknown component type %q (chart %q, %s). Known types: %s. Genuinely new kinds are added to krypton-lib.componentCatalog in krypton-lib/templates/_helpers.tpl." .component .ctx.Chart.Name (.origin | default "component argument") (keys $catalog | sortAlpha | join ",")) -}}
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

    [<prefix>-]<subchart-name>-<global-lane-name>[-<instance>]
    e.g. krypton-banking-release             Deployment, Service, Route, SA, ...
         krypton-banking-release-database    VaultStaticSecret, instance "database"
         acme-krypton-banking-release        the same Deployment with
                                             global.namePrefix "acme"

  prefix          optional, from the umbrella's global.namePrefix; empty
                  (the default) renders no prefix segment at all
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
prune lookup. Consequence: several resources of the SAME kind in one
subchart need distinct instances, and a Secret written by a
VaultStaticSecret (destination.name) must not reuse the instance of a plain
Secret rendered by the same subchart.

"shared" true drops the lane segment for resources that are not lane
specific - a ConfigMap or Secret that every lane deployment of the subchart
consumes and that therefore only has to exist once:
    krypton-banking
    krypton-banking-smtp
A configured global.namePrefix is kept (acme-krypton-banking-smtp): the
prefix separates umbrellas, the lane segment separates lanes.
Use the same call (with "shared" true) both where the resource is created
and where it is referenced, and let exactly ONE deployment create it; the
others reference the name only.

Referencing another subchart's resource: "chart" replaces the caller's
.Chart.Name with the owning subchart's name, everything else stays the
same. This is how the application subcharts point at the objects of the
krypton-shared subchart without spelling out a name - both sides call the
helper with identical arguments, so the reference can never drift:
    krypton-shared/templates/configmaps.yaml   (creates)
        (dict "ctx" $root "component" "configMap" "instance" "common" "shared" true)
    krypton-banking/templates/deployment.yaml  (references)
        (dict "ctx" $ "chart" "krypton-shared" "component" "configMap" "instance" "common" "shared" true)
    -> krypton-shared-common on both sides

Truncated to 63 characters (the Kubernetes name limit for most resources).

Usage:
    name: {{ include "krypton-lib.componentName" (dict "ctx" . "component" "deployment") }}
    name: {{ include "krypton-lib.componentName" (dict "ctx" . "component" "vaultStaticSecret" "instance" "database") }}
    name: {{ include "krypton-lib.componentName" (dict "ctx" . "component" "configMap" "shared" true) }}
    name: {{ include "krypton-lib.componentName" (dict "ctx" . "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true) }}
*/}}
{{- define "krypton-lib.componentName" -}}
{{- $ctx := .ctx -}}
{{- $component := required "krypton-lib.componentName: 'component' is required" .component -}}
{{- include "krypton-lib.assertComponent" (dict "ctx" $ctx "component" $component) -}}
{{- $name := .chart | default $ctx.Chart.Name -}}
{{- with include "krypton-lib.namePrefix" . -}}
{{- $name = printf "%s-%s" . $name -}}
{{- end -}}
{{- if not .shared -}}
{{- $name = printf "%s-%s" $name (include "krypton-lib.laneName" .) -}}
{{- end -}}
{{- with .instance -}}
{{- $instance := regexReplaceAll "([a-z0-9])([A-Z])" (toString .) "${1}-${2}" | lower -}}
{{- $instance = regexReplaceAll "[^a-z0-9-]" $instance "-" -}}
{{- $name = printf "%s-%s" $name $instance -}}
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
                                 krypton-banking-release)
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
  1. chart-generated standard labels (app.kubernetes.io/*, helm.sh/chart);
     the lane is stamped as app.kubernetes.io/part-of: [<partOfPrefix>-]<laneName>
  2. global.labels                  - static platform labels from the umbrella

The app.kubernetes.io/part-of lane label is omitted for "shared" resources
(see componentName): a resource consumed by several lanes belongs to none.

Usage:
    labels:
      {{- include "krypton-lib.labels" (dict "ctx" .) | nindent 4 }}
*/}}
{{- define "krypton-lib.labels" -}}
{{- $ctx := .ctx -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $labels := dict
      "helm.sh/chart"                (include "krypton-lib.chart" .)
      "app.kubernetes.io/name"       $ctx.Chart.Name
      "app.kubernetes.io/instance"   $ctx.Release.Name
      "app.kubernetes.io/managed-by" $ctx.Release.Service
-}}
{{- if not .shared -}}
{{- $_ := set $labels "app.kubernetes.io/part-of" (include "krypton-lib.partOf" .) -}}
{{- end -}}
{{- with $ctx.Chart.AppVersion -}}
{{- $_ := set $labels "app.kubernetes.io/version" (. | toString) -}}
{{- end -}}
{{- $labels = mergeOverwrite $labels (deepCopy ($global.labels | default dict)) -}}
{{- toYaml $labels -}}
{{- end }}

{{/*
Pod selector labels - the identity subset of krypton-lib.labels that
Deployment, Service, PodDisruptionBudget and NetworkPolicy selectors match
pods by. Exactly three keys, each carrying the same value the pod template
receives from krypton-lib.labels:

    app.kubernetes.io/name       <subchart-name>        (.Chart.Name)
    app.kubernetes.io/instance   <release-name>         (.Release.Name)
    app.kubernetes.io/part-of    [<partOfPrefix>-]<laneName>

The lane label is part of the identity so a Service or NetworkPolicy of one
lane can never select the pods of another lane that happens to share the
namespace and release name. It is NOT an argument: pods are never "shared",
so the selector always carries the lane.

A Deployment's selector is immutable, which makes every value here a
one-way door: changing global.laneName renames the Deployment anyway (a
new object with a new selector), but changing global.partOfPrefix on an
existing lane changes only the selector and the apply is rejected - delete
the Deployments of that lane once, then sync again. Never add chart
version, custom labels or anything else that varies between syncs.

Usage:
    selector:
      matchLabels:
        {{- include "krypton-lib.selectorLabels" (dict "ctx" .) | nindent 8 }}
*/}}
{{- define "krypton-lib.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/part-of: {{ include "krypton-lib.partOf" . }}
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

  1. chart-generated standard annotations (<labelDomain>/source-chart)
  2. global.annotations              - static annotations from the umbrella
  3. .Values.jenkins.annotations     - CI-injected annotations (build number,
                                       commit, job URL, ...), set per subchart
                                       from the umbrella as
                                       <subchart-name>.jenkins.annotations,
                                       typically via ArgoCD helm parameters.
                                       Only merged when the block exists;
                                       values are stringified so a numeric
                                       build id from --set stays a valid
                                       annotation value.
  4. extra                           - optional per-call additions
  5. argocd.argoproj.io/sync-wave    - resolved via krypton-lib.syncWave
  6. argocd.argoproj.io/sync-options - resolved via krypton-lib.syncOptions
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
      (printf "%s/source-chart" $domain) (include "krypton-lib.chart" .)
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
      $jenkinsAnnotations
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
      {{- include "krypton-lib.metadata" (dict "ctx" . "component" "configMap") | nindent 2 }}
*/}}
{{- define "krypton-lib.metadata" -}}
name: {{ include "krypton-lib.componentName" . }}
labels:
  {{- include "krypton-lib.labels" . | nindent 2 }}
annotations:
  {{- include "krypton-lib.annotations" . | nindent 2 }}
{{- end }}
