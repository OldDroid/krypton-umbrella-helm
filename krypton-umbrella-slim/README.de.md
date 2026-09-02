# krypton-umbrella-slim

Die schlanke Variante des Krypton-Umbrella-Charts. Das Library-Chart
(`krypton-lib-slim`) erzeugt den **Metadata-Block** eines Manifests und
sonst nichts:

- einheitliche Ressourcennamen, mit optionalem **Instanz-Bezeichner** für
  mehrere Ressourcen derselben Art in einem Subchart
- zusammengeführte **Labels** und **Annotations** (Plattform → Umbrella →
  Subchart → Aufrufstelle)
- ArgoCD-**Sync-Waves** (je Komponententyp, mit Offset je Subchart)
- ArgoCD-**Sync-Options** (beliebige `argocd.argoproj.io/sync-options`-
  Einträge: `Prune=false`, `Delete=false`, `Replace=true`, ...)

Alles unterhalb von `metadata:` (Images, ServiceAccounts, Probes, Volumes,
Selektoren) schreibt das Subchart selbst. Diese Variante passt, wenn die
App-Teams ihre Manifeste besitzen und die Plattform nur konsistentes Naming,
Labelling und Ordering braucht; das volle `krypton-umbrella` passt, wenn die
Plattform auch die Workload-Spec standardisieren soll.

Für die Helm-3-Linie geschrieben (ArgoCD nutzt Helm 3): keine
Helm-4-exklusiven Features, Verzeichnis-Abhängigkeiten ohne Repository,
JSON Schema draft-07.

## Aufbau

```
krypton-umbrella-slim/
├── Chart.yaml                  # deklariert alle Charts unter charts/ (Helm 3 toleriert, Helm 4 verlangt es)
├── values.yaml                 # global: Lane, Labels/Annotations, Default-Waves & Sync-Options
├── values.schema.json          # validiert global plus die lib-relevanten Keys jedes Subchart-Blocks
├── values-shared-only.yaml     # Overlay für den shared-Eigentümer: krypton-shared an, Anwendungs-Subcharts aus
└── charts/
    ├── krypton-lib-slim/       # type: library - rendert nichts, stellt die Metadata-Helper bereit
    │   └── templates/_helpers.tpl
    ├── krypton-payments/       # ServiceAccount, 2 ConfigMaps, 2 Secrets, 2 VaultStaticSecrets,
    │                           # Deployment, Service, Route - Instanz-Bezeichner in Aktion
    ├── krypton-notifier/       # ConfigMap, Deployment, Service - minimal, Wave-Offset 10
    └── krypton-shared/         # lane-unabhängige ConfigMaps / Secrets / VaultStaticSecrets, ein Eigentümer je Namespace
```

Jedes Subchart deklariert das Library-Chart als lokale Abhängigkeit, damit
es eigenständig gebaut und gerendert werden kann (`file://../krypton-lib-slim`);
unter dem Umbrella lädt Helm die Templates aller Charts in einen gemeinsamen
Namensraum, die `krypton-lib-slim.*`-Helper sind ohne Vendoring auflösbar.

## Die Helper

Jeder Helper nimmt ein Dict; `ctx` ist der Root-Kontext des Aufrufers (`.`
im Template, `$` innerhalb eines `range`).

| Helper | Argumente | Erzeugt |
| --- | --- | --- |
| `krypton-lib-slim.metadata` | `ctx`, `component`, `instance?`, `extraLabels?`, `extraAnnotations?` | `name:` + `labels:` + `annotations:` |
| `krypton-lib-slim.componentName` | `ctx`, `component`, `instance?` | den Ressourcennamen (auch für Querverweise) |
| `krypton-lib-slim.labels` | `ctx`, `extraLabels?` | die zusammengeführte Label-Map |
| `krypton-lib-slim.selectorLabels` | `ctx` | die unveränderliche Identitäts-Teilmenge für Selektoren |
| `krypton-lib-slim.annotations` | `ctx`, `component`, `extraAnnotations?` | die zusammengeführte Annotation-Map inkl. der ArgoCD-Einträge |
| `krypton-lib-slim.syncWave` | `ctx`, `component` | die aufgelöste Wave, `""` wenn keine |
| `krypton-lib-slim.syncOptions` | `ctx`, `component` | die kommagetrennten Sync-Options, `""` wenn keine |

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

### Namen und der Instanz-Bezeichner

`componentName` erzeugt `<subchart-name>-<global.laneName>[-<instance>]`.
Der Komponententyp ist bewusst nicht Teil des Namens – der Kubernetes-Kind
unterscheidet ein Deployment ohnehin von einem Service namens
`krypton-payments-release`. Das `component`-Argument bleibt trotzdem
Pflicht: Es wird gegen den Katalog validiert und wählt Sync-Wave und
Sync-Options aus.

Rendert ein Subchart mehrere Ressourcen einer Art, wird ein `instance`
übergeben und angehängt, normalisiert auf ein DNS-1123-Label
(camelCase-Grenzen werden zu Bindestrichen, alles wird kleingeschrieben,
andere Zeichen werden zu Bindestrichen). krypton-payments rendert seine
ConfigMaps, Secrets und VaultStaticSecrets aus Maps und nimmt den Map-Key
als Instanz:

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

ergibt (Lane `release`):

```
krypton-payments-release               # ServiceAccount, Deployment, Service, Route - ein Name, vier Kinds
krypton-payments-release-app           # ConfigMap "app" und VaultStaticSecret "app" - verschiedene Kinds
krypton-payments-release-logging       # ConfigMap
krypton-payments-release-smtp          # Secret
krypton-payments-release-signing       # Secret
krypton-payments-release-database      # VaultStaticSecret (schreibt das gleichnamige Secret)
krypton-notifier-release               # ConfigMap, Deployment, Service - ohne Instanz
```

Weil nur der Kind Ressourcen gleichen Namens trennt, brauchen zwei
Ressourcen *derselben* Art verschiedene Instanzen. Die eine Falle ist das
Secret, das ein VaultStaticSecret schreibt: krypton-payments verweigert das
Rendern, wenn ein Key sowohl in `secrets` als auch in `vault.secrets`
vorkommt.

Das Deployment referenziert dieselben Namen über denselben Helper, ein
`envFrom`-Eintrag und die Ressource dahinter können nie auseinanderlaufen:

```yaml
- secretRef:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" $ "component" "vaultStaticSecret" "instance" $name) }}
```

### Geteilte Ressourcen ohne Lane

Eine ConfigMap oder ein Secret, das mehrere Lane-Deployments gemeinsam
nutzen, muss nur einmal existieren. Mit `shared: true` entfällt das
Lane-Segment im Namen, und das `app.kubernetes.io/part-of`-Lane-Label wird
nicht gesetzt:

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" $root "component" "secret" "instance" $name "shared" true) | nindent 2 }}
```

```
krypton-payments-smtp                 # statt krypton-payments-release-smtp
krypton-payments                      # ohne Instanz
```

Plattformweit geteilte Objekte leben in einem eigenen Subchart,
**`krypton-shared`**, das `configMaps`, `secrets` und `vault.secrets` als
`krypton-shared-<key>` rendert. Genau eine ArgoCD-Application pro Namespace
darf sie besitzen (ArgoCD meldet einen zweiten Eigentümer als Shared
Resource, Helm verweigert fremde Eigentümerschaft), die Eigentümerschaft
ist deshalb der gewöhnliche Deploy-Schalter `krypton-shared.enabled`:

| Application | Values |
| --- | --- |
| Konsumenten-Lane (Default) | `krypton-shared.enabled: false` – Workloads referenzieren die Namen, nichts wird erzeugt |
| Eigentümer-Lane | `krypton-shared.enabled: true` neben den aktivierten Anwendungs-Subcharts |
| eigene shared-Application | `-f values-shared-only.yaml` – `krypton-shared` an, jedes Anwendungs-Subchart aus |

krypton-payments referenziert sie über denselben Helper, der sie benennt,
`chart` pinnt den Eigentümer – eine Referenz kann so nie abdriften:

```yaml
- secretRef:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" $ "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true) }}
# -> krypton-shared-gateway, exakt das, was krypton-shared/templates/secrets.yaml rendert
```

angeboten als `sharedEnvFrom.configMaps` / `.secrets` (Instanz-Keys, als
`envFrom` verdrahtet; der Umbrella verdrahtet `common` und `gateway`).

```bash
helm template krypton krypton-umbrella-slim -f krypton-umbrella-slim/values-shared-only.yaml   # nur krypton-shared-common / -gateway
helm template krypton krypton-umbrella-slim --set krypton-shared.enabled=true                  # Eigentümer-Lane: alles
```

Der Katalog (`krypton-lib-slim.componentCatalog` in `_helpers.tpl`) ist die
einzige Quelle für Komponenten-Strings; ein unbekanntes `component`-Argument
oder ein unbekannter `syncWaves`/`syncOptions`-Key lässt den Render mit dem
Katalog in der Fehlermeldung scheitern. Ein wirklich neuer Kind ist eine
ergänzte Zeile.

### Labels

Merge-Reihenfolge, spätere gewinnen bei Key-Kollisionen:

1. Standard-Labels: `app.kubernetes.io/name|instance|version|managed-by`,
   `helm.sh/chart` sowie die Lane als `app.kubernetes.io/part-of` (entfällt
   bei `shared`-Ressourcen; `global.partOfPrefix` stellt den Umbrella-Namen
   voran, `krypton-umbrella-slim-release` statt `release`)
2. `global.labels` — umbrella-weit
3. `<subchart>.labels` — der `labels:`-Block des Subcharts, aus dem
   Umbrella-Block überschreibbar (der Umbrella ergänzt `krypton.io/team: payments`)
4. `extraLabels` — je Aufruf

`selectorLabels` ist nur `app.kubernetes.io/name` + `app.kubernetes.io/instance`
(`instance` ist der Helm-Release-Name, also der Name der ArgoCD-Application);
nie veränderliche Werte in einen Selektor aufnehmen.

### Annotations

1. Standard: `<labelDomain>/source-chart`
2. `global.annotations`
3. `<subchart>.annotations` (krypton-notifier bekommt `krypton.io/on-call`
   aus dem Umbrella)
4. `<subchart>.jenkins.annotations` — von der CI injiziert, **nur wenn der
   Block existiert**; per Default nicht vorhanden, ein einfacher Render trägt
   also keine CI-Annotations. Jenkins setzt ihn pro Sync, z. B. über
   ArgoCD-Helm-Parameter
   `krypton-payments.jenkins.annotations.jenkins\.io/build-number=1234`;
   skalare Werte werden zu Strings, eine numerische Build-ID ist damit sicher.
5. `extraAnnotations` — je Aufruf; die Route reicht `.Values.route.annotations`
   durch (`haproxy.router.openshift.io/timeout`)
6. `argocd.argoproj.io/sync-wave`
7. `argocd.argoproj.io/sync-options`

Die beiden ArgoCD-Annotations kommen zuletzt und lassen sich nicht
überdecken; jede entfällt, wenn nichts konfiguriert ist.

### Sync-Waves

Aufgelöst je Komponenten**typ**, erster Treffer gewinnt:

1. `<subchart>.syncWaves.<component>` (Subchart-Values, bereits mit dem
   Umbrella-Block koalesziert)
2. `global.syncWaves.<component>`

Alle Instanzen eines Typs teilen sich die Wave: jedes VaultStaticSecret von
krypton-payments synct bei `-1`, jede ConfigMap bei `0`. `syncWaveOffset`
(je Subchart, aus dem Umbrella gesetzt) wird auf jede aufgelöste Wave
addiert und stempelt unkonfigurierte Komponenten mit dem nackten Offset,
das Subchart verschiebt sich als ein Block: krypton-notifier mit Offset
`10` rendert ConfigMap `10`, Deployment/Service `11`, komplett hinter
krypton-payments (`-2..3`). Komponenten-Waves in `-9..9` halten, Offsets in
Zehnerschritten vergeben.

### Sync-Options

`syncOptions.<component>` nimmt eine **Liste** von ArgoCD-Sync-Options auf
Ressourcenebene (ein kommagetrennter String geht auch), gleiche
Auflösungskette wie die Waves; der erste Treffer ersetzt, Listen werden nie
gemischt:

```yaml
global:
  syncOptions:
    vaultStaticSecret: ["Prune=false"]            # Plattformregel

krypton-payments:
  syncOptions:
    route: ["Prune=false", "Delete=false"]         # öffentliche Route auch beim Löschen der App behalten
    vaultStaticSecret: []                          # würde die Plattformregel für dieses Subchart abschalten
```

rendert `argocd.argoproj.io/sync-options: Prune=false,Delete=false` auf der
Route. Weitere nützliche Einträge: `Replace=true`, `ServerSideApply=true`,
`SkipDryRunOnMissingResource=true` (CRD noch nicht installiert), `PruneLast=true`.

### Values-Vertrag

| Key | Ebene | Bedeutung |
| --- | --- | --- |
| `global.laneName` | Umbrella, **Pflicht** | Lane; Teil jedes Namens; Render scheitert ohne |
| `global.labelDomain` | Umbrella | Präfix der erzeugten `<domain>/source-chart`-Annotation, Default `krypton.io` |
| `global.labels` / `global.annotations` | Umbrella | statische Maps für jede Ressource |
| `global.syncWaves` / `global.syncOptions` | Umbrella | Plattform-Defaults je Komponententyp |
| `labels` / `annotations` | Subchart | eigene Maps für jede Ressource des Subcharts |
| `jenkins.annotations` | Subchart, optional | CI-injizierte Annotations; nur gemergt, wenn vorhanden |
| `syncWaves` / `syncOptions` | Subchart | Overrides je Typ, gewinnen gegen global |
| `syncWaveOffset` | Subchart | verschiebt das ganze Band, Default `0` |
| `enabled` | Umbrella-Block | Deploy-Schalter via `condition:` in der Umbrella-`Chart.yaml` |

Die Umbrella-`values.schema.json` typisiert genau diese Keys (und lässt den
Rest jedes Subchart-Blocks dem Subchart). Die schlanke Variante bringt
bewusst keine Subchart-Schemas mit; ein Subchart bekommt eines, wenn seine
eigenen Keys validiert werden sollen.

## Alltagskommandos

```bash
helm lint krypton-umbrella-slim
helm template krypton krypton-umbrella-slim                              # Release-Lane rendern
helm template krypton krypton-umbrella-slim --set global.laneName=test   # andere Lane
```

Eigenständige Arbeit an einem Subchart (vendort die Library, liefert eine Lane):

```bash
helm dependency build krypton-umbrella-slim/charts/krypton-payments
helm template t krypton-umbrella-slim/charts/krypton-payments --set global.laneName=dev
```

Die erzeugten `charts/*/charts/` und `Chart.lock` sind gitignored.

## Ein Subchart ergänzen

1. `charts/krypton-<name>/` mit `Chart.yaml` (`krypton-lib-slim` via
   `file://../krypton-lib-slim` deklarieren), `values.yaml`, `templates/`.
2. In die `dependencies:` der Umbrella-`Chart.yaml` aufnehmen (Name +
   Version, ohne Repository) mit `condition: krypton-<name>.enabled`, in den
   Umbrella-Values `enabled: true` setzen und
   `"krypton-<name>": { "$ref": "#/definitions/subchartBlock" }` ins
   Umbrella-Schema eintragen.
3. Für jeden Metadata-Block `krypton-lib-slim.metadata` verwenden; überall
   dort ein `instance` übergeben, wo ein Kind mehrfach vorkommt; andere
   Ressourcen über `krypton-lib-slim.componentName` referenzieren.
4. `syncWaves` / `syncOptions` im Subchart oder im Umbrella-Block setzen, wo
   die globalen Defaults nicht passen.

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
      prune: true        # respektiert die sync-options-Annotations je Ressource
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

ArgoCD führt vor dem Templating eines Git-Charts `helm dependency build`
aus; bei Verzeichnis-Abhängigkeiten ohne Repository gibt dieser Schritt nur
"Assuming it exists in the charts directory" je Eintrag aus und lässt die
Verzeichnis-Charts unangetastet. Es wird bewusst keine `Chart.lock`
committet: eine veraltete ließe diesen Schritt mit "Chart.lock is out of
sync" scheitern.
