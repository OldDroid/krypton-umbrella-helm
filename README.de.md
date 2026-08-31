# krypton-umbrella

Helm-Umbrella-Chart für die Krypton-Plattform, deployt via ArgoCD nach
Kubernetes/OpenShift. Alle Subcharts teilen sich ein Library-Chart
(`krypton-lib`), das die Namenskonvention der Plattform, Standard-Labels,
zusammengeführte Annotations und dynamische ArgoCD-Sync-Waves durchsetzt.

## Aufbau

```
krypton-umbrella/
├── Chart.yaml                  # deklariert alle Charts unter charts/ (von Helm 4 gefordert)
├── values.yaml                 # global: Lane, statische Labels/Annotations, Default-Sync-Waves
├── values.schema.json          # validiert die Umbrella-Keys, insb. global
└── charts/
    ├── krypton-lib/            # type: library - rendert nichts, stellt die Helper bereit
    │   └── templates/_helpers.tpl
    ├── krypton-banking/        # Deployment, Service, ConfigMap, VaultStaticSecret, Route,
    │                           # ServiceAccount (+ optional PDB / HPA / NetworkPolicy)
    └── krypton-auth/           # Deployment, ServiceAccount
```

Jedes Subchart deklariert das Library-Chart als lokale Abhängigkeit:

```yaml
dependencies:
  - name: krypton-lib
    version: 0.1.0
    repository: file://../krypton-lib
```

Beim Rendern des Umbrella-Charts lädt Helm die Templates aller Charts in
einen gemeinsamen Namensraum; die `krypton-lib.*`-Helper sind daher ohne
Vendoring auflösbar. Die `file://`-Abhängigkeit erlaubt zusätzlich, jedes
Subchart eigenständig zu bauen und zu rendern (siehe unten).

## Konventionen

**Ressourcennamen** – `krypton-lib.componentName` erzeugt
`<subchart-name>-<global.laneName>-<komponenten-shortname>`, z. B.
`krypton-banking-release-deploy`. Als Namens-Suffix dient der im Katalog
hinterlegte Kubernetes-Shortname des Komponententyps (`configMap` → `cm`,
`service` → `svc`); Typen ohne Shortname fallen auf den kebab-case-Typ
zurück (`vaultStaticSecret` → `vault-static-secret`). Labels und
Annotations behalten den vollen kebab-case-Typ (`config-map`) – nur Namen
werden gekürzt. Rendert ein Subchart mehrere Ressourcen desselben
Komponententyps, wird ein optionales `instance`-Argument als weiterer
kebab-case-Suffix angehängt
(`krypton-banking-release-vault-static-secret-database`). Ist
`global.laneName` nicht gesetzt, schlägt das Rendern mit einer klaren
Fehlermeldung fehl.

**Label-Domain** – die plattformgenerierten Label-/Annotation-Keys
(`<domain>/lane`, `<domain>/component`, `<domain>/source-chart`) beziehen
ihr Präfix aus `global.labelDomain` (Default `krypton.io`); das Gerüst lässt
sich damit über einen einzigen Values-Key für andere Projekte umbenennen.
Die statischen Keys unter `global.labels`/`global.annotations` sind
gewöhnliche Values und werden einfach mit angepasst.
`app.kubernetes.io/instance` ist der Helm-Release-Name (der Name der
ArgoCD-Application), kein fest verdrahteter Wert.

**Workload-Konfiguration** – `krypton-lib.image` baut die Image-Referenz
aus `image.registry`/`repository`/`tag` (oder `digest`) zusammen; mit
`global.imageRegistry` zeigt jedes Subchart über einen einzigen Key auf
eine Lane-spezifische Proxy- oder Air-Gapped-Registry. Jedes Subchart läuft
unter einem eigenen ServiceAccount (Komponente `serviceAccount`, Wave `-2`,
benannt über `krypton-lib.serviceAccountName` – VaultAuth-Kubernetes-Rollen
an genau diesen Namen binden, oder mit `serviceAccount.create: false` plus
`name:` einen bestehenden SA referenzieren). `vault.secrets` rendert je Eintrag ein
VaultStaticSecret (der Key wird zum Instance-Suffix des Namens;
`authRef`/`mount`/`refreshAfter` sind geteilte Defaults mit Overrides pro
Secret, und `envFrom: true` verdrahtet das materialisierte Secret ins
Deployment); alle Instanzen teilen sich Sync-Wave und Prune-Schutz des
Komponententyps. Secret-Pfade und `route.host` laufen durch `tpl`; die
Default-Pfade templaten die Lane hinein, jede Lane liest also ihre eigenen
Secrets. Die ConfigMap-Zustellung steuert der `config`-Block: `data` hält
die Keys, `envFrom` exponiert sie als Env-Variablen, `mountPath` mountet
sie zusätzlich als vom Kubelet aktualisierte Dateien, und
`rollPodsOnChange` schaltet den Checksum-Rollout &mdash; nur für Services
deaktivieren, die ihre gemountete Config-Datei selbst nachladen, denn
Env-Variablen aktualisieren sich in laufenden Containern nie. `resources:` liegen je Subchart vor
und werden pro Lane aus dem Umbrella-Chart dimensioniert. Pod-Passthroughs
(`extraEnv`, `extraEnvFrom`, `podAnnotations`, `nodeSelector`,
`tolerations`, `affinity`) wandern unverändert in die Pod-Spec – App-Teams
müssen nie ein Template forken. Optionale Komponenten folgen dem
Enabled-Flag-Muster pro Lane: `podDisruptionBudget` (die Release-Lane
aktiviert es für banking), `autoscaling` (solange aktiv, rendert das
Deployment kein `spec.replicas` mehr, ArgoCD und HPA streiten also nie um
die Replikazahl) und `networkPolicy` (Namespace-intern plus
OpenShift-Router-Ingress).

**Sync-Waves** – `krypton-lib.syncWave` löst pro Komponententyp auf, der
erste Treffer gewinnt:

1. `.Values.syncWaves.<komponente>` des Subcharts — enthält dank
   Helm-Coalescing bereits jedes Umbrella-Override aus
   `<subchart-name>.syncWaves.<komponente>`
2. `global.syncWaves.<komponente>` — plattformweite Defaults

`krypton-lib.annotations` setzt die Wave als `argocd.argoproj.io/sync-wave`
ganz am Ende seiner Merge-Kette (Standard → `global.annotations` → `extra`
pro Aufruf → Wave) und lässt sie weg, wenn keine Wave konfiguriert ist.
Aktuelle Reihenfolge für krypton-banking: VaultStaticSecret `-1` →
ConfigMap `0` → Deployment/Service `1` → Route `3` — das von Vault
materialisierte Secret existiert also, bevor das Deployment es einbindet,
und die Route geht zuletzt live. Die Waves orientieren sich nur deshalb an
echter Anwendungsgesundheit, weil die Deployments konfigurierbare
Readiness-/Liveness-Probes tragen (`probes:` je Subchart, pro Lane
überschreibbar); das Pod-Template von banking trägt per Default zusätzlich
eine `checksum/config`-Annotation, damit ConfigMap-Änderungen die Pods neu
ausrollen.

**Subchart-übergreifende Reihenfolge** – soll ein Subchart erst nach einem
anderen syncen, verschiebt `syncWaveOffset` (je Subchart, gesteuert aus dem
Umbrella-Chart) dessen komplettes Wave-Band: Der Offset wird auf jede
aufgelöste Wave addiert, und Komponenten ohne konfigurierte Wave – in
ArgoCD implizit Wave 0 – bekommen den nackten Offset annotiert, das
Subchart wandert also als ein Block mit unveränderter innerer Reihenfolge.
Das Umbrella-Chart deployt krypton-auth mit Offset `10`, d. h. vollständig
nach banking (ServiceAccount `8`, Deployment `11`, während banking `-2..3`
belegt). Komponenten-Waves innerhalb von `-9..9` halten und Offsets in
10er-Schritten vergeben, dann überlappen sich die Bänder nie.

**Komponentenkatalog** – `krypton-lib.componentCatalog` (in `_helpers.tpl`)
ist die einzige Quelle der Wahrheit für Komponententyp-Strings und ordnet
jedem Typ den Kubernetes-Shortname für die Ressourcennamen zu (leer =
kein Shortname, es wird der kebab-case-Typ verwendet). Jedes
`component`-Argument und jeder konfigurierte `syncWaves`-/`syncPrune`-Key
(auf Subchart- wie auf global-Ebene) wird beim Rendern dagegen geprüft; ein
unbekannter String wie `syncWaves.rout` lässt das Rendern fehlschlagen, mit
dem Katalog in der Fehlermeldung. Einen katalogisierten Typ zu
konfigurieren, den ein Subchart (noch) nicht rendert, ist erlaubt und
bleibt schlicht wirkungslos — Waves und Prune-Flags lassen sich also schon
vor dem Manifest anlegen. Der Katalog deckt die gängigen
Kubernetes-/OpenShift-/VSO-Kinds ab; ein wirklich neuer Typ ist eine
zusätzliche Zeile (Typ plus Shortname, leer für keinen), ohne
Schema-Änderungen.

**Values-Schemas** – jedes Chart bringt eine `values.schema.json` mit, die
Helm bei jedem lint/template/install gegen die *koaleszierten* Values des
Charts validiert. Die Schemas sind strikt bei der Struktur
(`additionalProperties: false` — ein vertippter `syncWave:`-Block wird
abgelehnt, auch wenn der Tippfehler im Subchart-Block des Umbrella-Charts
passiert) und bei den Wertformen (Waves müssen Ganzzahlen bzw.
Ganzzahl-Strings sein, Prune-Flags Booleans); die *Zugehörigkeit* der
Komponenten-Keys prüft der Katalog, siehe oben. Wer einen Values-Key
ergänzt, erweitert im selben Commit das Schema des Charts. Keys, die
externes Tooling in `global` injiziert, müssen ins Umbrella-Schema
aufgenommen werden — dort ist es mit Absicht strikt.

**Prune-Schutz** – `krypton-lib.syncOptions` löst pro Komponente über
dieselbe Kette auf (erst `syncPrune.<komponente>` aus Subchart/Umbrella,
dann `global.syncPrune.<komponente>`). Der Wert `false` stempelt die
Ressource mit `argocd.argoproj.io/sync-options: Prune=false`; sie überlebt
damit das Pruning auf App-Ebene, selbst wenn ihr Manifest aus Git
verschwindet oder ihr Subchart deaktiviert wird — ArgoCD meldet die
Application dann so lange OutOfSync, bis die Ressource manuell gelöscht
wird. Ein `true` reaktiviert das Pruning für eine global geschützte
Komponente. Aktuelle Defaults: alle VaultStaticSecrets (`global.syncPrune`)
sowie die banking-Route (Umbrella-Block) sind geschützt.

**Deploy-Schalter** – jedes Anwendungs-Subchart hängt an einem
`condition: <subchart-name>.enabled`-Flag am Dependency-Eintrag der
Umbrella-`Chart.yaml`, gesteuert über die Umbrella-Values:

```yaml
krypton-banking:
  enabled: true
```

Auf `false` gesetzt (in einer Lane-Values-Datei oder via ArgoCD
`helm.parameters`) fliegt das komplette Subchart aus dem Release; ArgoCD
räumt seine Ressourcen anschließend per Pruning ab — mit Ausnahme der über
`syncPrune` geschützten Komponenten (siehe oben). Ein fehlendes Flag zählt
als aktiviert, deshalb sind die Flags explizit deklariert. `krypton-lib`
hat bewusst keine Condition: Ein Deaktivieren würde die gemeinsamen Helper
aus dem Render-Namensraum entfernen und jedes aktivierte Subchart brechen.

## Alltagskommandos

```bash
helm lint krypton-umbrella
helm template krypton krypton-umbrella                                # rendert die Release-Lane
helm template krypton krypton-umbrella --set global.laneName=test     # rendert eine andere Lane
```

### Arbeiten an einem einzelnen Subchart

Eigenständiges Rendern braucht das ins Subchart gevendorte Library-Chart
und eine explizit angegebene Lane (es gibt ja kein Umbrella-Chart, das sie
liefert):

```bash
helm dependency build krypton-umbrella/charts/krypton-banking
helm template t krypton-umbrella/charts/krypton-banking --set global.laneName=dev
```

Die dabei erzeugten `charts/*/charts/` und `charts/*/Chart.lock` sind
absichtlich per `.gitignore` ausgeschlossen: Eine veraltete gevendorte
Kopie von krypton-lib darf beim Rendern des Umbrella-Charts niemals die
aktive Kopie unter `charts/krypton-lib` verdecken.

### Einen neuen Komponententyp in einem Subchart ergänzen (z. B. eine NetworkPolicy)

1. Das Manifest im `templates/`-Verzeichnis des Subcharts anlegen und den
   gemeinsamen Metadata-Helper mit einem neuen Komponententyp-Key aufrufen:

   ```yaml
   metadata:
     {{- include "krypton-lib.metadata" (dict "ctx" . "component" "networkPolicy") | nindent 2 }}
   ```

   Der Namens-Suffix kommt aus dem Shortname im Katalog
   (`krypton-banking-release-netpol`); Typen ohne Shortname werden
   automatisch nach kebab-case umgesetzt.
2. Nur wenn der Typ für die Plattform wirklich neu ist: in
   `krypton-lib.componentCatalog` in `_helpers.tpl` eintragen — eine Zeile,
   die den Typ auf seinen Shortname abbildet (leer für keinen), keine
   Schema-Änderungen. Bereits katalogisierte Typen (networkPolicy ist
   es) brauchen nirgendwo eine Registrierung; ihre
   `syncWaves`-/`syncPrune`-Einträge dürfen sogar schon vor dem Manifest
   existieren.
3. Eine Wave im passenden Band vergeben: `syncWaves.networkPolicy` in den
   Subchart-Values, ein Plattform-Default unter `global.syncWaves` oder ein
   Lane-Override im Subchart-Block des Umbrella-Charts (z. B. `"0"`, damit
   Policies vor den Workloads existieren).
4. Optional vor dem Pruning schützen: `syncPrune.networkPolicy: false`.

Am Library-Chart ist nichts zu ändern — Naming, Labels, Annotations sowie
Wave- und Prune-Auflösung hängen alle nur am Komponenten-String.

### Ein neues Subchart ergänzen

1. `charts/krypton-<name>/` mit `Chart.yaml` (die `krypton-lib`-Abhängigkeit
   via `file://../krypton-lib` deklarieren), `values.yaml`,
   `values.schema.json` (das von krypton-auth als Startpunkt kopieren) und
   `templates/`.
2. In die `dependencies:`-Liste der Umbrella-`Chart.yaml` aufnehmen (Name +
   Version, ohne repository-Feld — Helm 4 verlangt, dass jedes Chart unter
   `charts/` deklariert ist), mit `condition: krypton-<name>.enabled`, und
   im zugehörigen Umbrella-Values-Block `enabled: true` setzen.
3. Für jeden Metadata-Block der Manifeste `krypton-lib.metadata` verwenden;
   Komponententypen in `syncWaves` / `syncPrune` ergänzen, wo die globalen
   Defaults nicht passen.
4. Optional einen `krypton-<name>:`-Block in der Umbrella-`values.yaml`
   anlegen.

## ArgoCD

Eine Application auf dieses Verzeichnis zeigen lassen; die Sync-Waves
ordnen die Ressourcen innerhalb jedes Syncs:

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

Pro Lane entweder je eine Values-Datei pflegen und in
`spec.source.helm.valueFiles` eintragen — oder die Lane direkt setzen:

```yaml
    helm:
      parameters:
        - name: global.laneName
          value: test
```

Verifiziert mit Helm v4.2.4 (das Chart ist Helm-3-kompatibel; es werden
keine Helm-4-exklusiven Features verwendet).
