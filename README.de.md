<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo-dark.svg">
  <img src="logo.svg" alt="Krypton-Logo" width="120">
</picture>

# krypton-umbrella

Dieses Helm-Chart bündelt die Anwendungen der Krypton-Plattform für Kubernetes und OpenShift. Argo CD kann daraus die Ressourcen erzeugen und im Cluster bereitstellen. Das Library-Chart `krypton-lib` stellt gemeinsame Template-Funktionen für Namen, Labels, Annotations, Images und ServiceAccounts bereit.

[English](README.md) · [Library-Referenz](charts/krypton-lib/README.de.md) · [Slim-Variante](krypton-umbrella-slim/README.de.md) · [Konfigurationsbeispiele](docs/index.html)

**Änderung der Library:** Überlange Namen werden jetzt abgelehnt. Bestehende Konfigurationen, die auf Kürzung angewiesen waren, müssen vor einem Upgrade angepasst und mit den bereitgestellten Ressourcennamen verglichen werden. Auch `partOfPrefix` und `laneName` zusammen dürfen als Label höchstens 63 Zeichen ergeben. Details und Grenzen der Prüfung stehen in der Library-Referenz.

## Begriffe und Aufbau

- **Umbrella-Chart:** das übergeordnete Chart in diesem Repository. Es aktiviert die Subcharts und überschreibt deren Standardwerte.
- **Subchart:** ein eingebundenes Chart, beispielsweise `krypton-banking`.
- **Library-Chart:** wiederverwendbare Template-Funktionen, im Folgenden „Helper“. Es erzeugt selbst keine Kubernetes-Ressourcen.
- **Lane:** eine benannte Bereitstellungsumgebung wie `release`, `test` oder `dev`. Eine Lane ist nicht automatisch ein eigener Namespace.
- **Rendern:** Helm setzt Templates und Values zu YAML-Manifesten zusammen. Dabei wird noch nichts im Cluster angelegt.
- **Sync-Wave:** eine Zahl, mit der Argo CD Ressourcen innerhalb einer Application nach ihrer Bereitstellungsreihenfolge gruppiert.

```text
./
├── Chart.yaml                  # Abhängigkeiten und Aktivierung der Subcharts
├── values.yaml                 # gemeinsame Werte und Overrides je Subchart
├── values.schema.json          # Validierung der Umbrella-Values
├── values-shared-only.yaml      # nur gemeinsam genutzte Ressourcen erzeugen
├── charts/
│   ├── krypton-lib/             # gemeinsame Helper
│   ├── krypton-banking/         # Deployment, Service, ConfigMap, VaultStaticSecrets,
│   │                           # Route, ServiceAccount; optional PDB und HPA
│   ├── krypton-auth/            # Deployment und ServiceAccount
│   └── krypton-shared/          # gemeinsame ConfigMaps, Secrets, VaultStaticSecrets
│                               # und eine NetworkPolicy für den Namespace
└── krypton-umbrella-slim/        # eigenständige Variante mit kleinerer Library
```

## Einstieg

Alle folgenden Befehle werden **im Stammverzeichnis dieses Repositorys** ausgeführt:

```bash
helm lint .
helm template krypton .
helm template krypton . --set global.laneName=test
```

Die Standardwerte sind Beispiele. Vor einer Installation müssen insbesondere Image-Adressen, Route-Hosts, Vault-Pfade und Zugangsdaten angepasst werden. OpenShift Routes benötigen die OpenShift-API; VaultStaticSecrets benötigen den Vault Secrets Operator und einen passenden VaultAuth. Ein erfolgreicher Render-Test prüft diese Cluster-Voraussetzungen nicht.

Standardmäßig referenziert Banking die gemeinsamen Objekte `krypton-shared-common` und `krypton-shared-gateway`, erzeugt sie aber nicht. Für einen vollständigen Erstaufbau entweder die gemeinsamen Ressourcen separat bereitstellen oder ihre Erzeugung in genau einer Lane einschalten:

```bash
# Nur gemeinsame Ressourcen rendern
helm template krypton-shared . -f values-shared-only.yaml
# Anwendungen und gemeinsame Ressourcen zusammen rendern
helm template krypton . --set krypton-shared.enabled=true
```

## Values setzen

`global` ist für alle Subcharts unter `.Values.global` sichtbar. Ein Block mit dem Namen eines Subcharts überschreibt dessen `values.yaml`. Beispiel für eine Datei `values-test.yaml`:

```yaml
global:
  laneName: test
krypton-banking:
  replicaCount: 1
  podDisruptionBudget:
    enabled: false
  syncWaves:
    route: "3"
```

```bash
helm template krypton . -f values-test.yaml
```

Nur `global.laneName=test` zu setzen ändert weder die Replikazahl noch das PDB oder die Ressourcenlimits. Dafür sind eigene Overrides nötig. Helm führt Maps zusammen; Listen werden ersetzt. Die Prüfung erfolgt gegen diese zusammengeführten Values.

## Ressourcennamen und Labels

`krypton-lib.componentName` erzeugt:

```text
[<namePrefix>-]<subchart>-<lane>[-<instance>]
```

Beispiel: Deployment, Service, Route und ServiceAccount von Banking heißen alle `krypton-banking-release`. Ihr Kubernetes-Ressourcentyp (`kind`) unterscheidet sie. **Es wird kein Typkürzel wie `-cm` angehängt.**

Für mehrere Ressourcen desselben Typs ist `instance` nötig, zum Beispiel `database` für `krypton-banking-release-database`. Großbuchstaben werden kleingeschrieben, camelCase-Grenzen und Sonderzeichen werden zu Bindestrichen. Namen mit mehr als 63 Zeichen oder ungültigem Format führen zu einer Fehlermeldung. Deshalb müssen auch die fertigen Namen eindeutig sein. Die Beispielcharts prüfen ihre ConfigMap-Maps sowie direkte Secrets und Vault-Ziel-Secrets auf solche Kollisionen. Bei eigenen Templates muss diese Prüfung ebenfalls eingebunden oder eine gleichwertige Prüfung ergänzt werden.

| Einstellung | Wirkung |
| --- | --- |
| `global.laneName` | Lane im Namen; im Umbrella erforderlich, Standard `release` |
| `global.namePrefix` | optionales Namenspräfix, z. B. `acme-krypton-banking-release` |
| `global.partOfPrefix` | Präfix nur für das Label `app.kubernetes.io/part-of`, z. B. `krypton-release` |
| `global.labelDomain` | Präfix der Annotation `<domain>/source-chart`, Standard `krypton.io` |
| `global.labels` | zusätzliche Labels für Ressourcen und Pods |
| `global.annotations` | zusätzliche Annotations für Ressourcen |

`app.kubernetes.io/name`, `app.kubernetes.io/instance` und `app.kubernetes.io/part-of` sind reservierte Identitätslabels. Eigene Labels überschreiben diese drei Werte nicht. Damit stimmen Pod-Labels und Selektoren überein. `instance` ist hier der Helm-Release-Name, nicht das gleichnamige Helper-Argument. Argo CD verwendet standardmäßig den Application-Namen als Release-Namen; `spec.source.helm.releaseName` kann ihn ändern. Bei abweichenden Namen ist außerdem Argo CDs Resource-Tracking-Konfiguration zu berücksichtigen.

Deployment-Selektoren sind unveränderlich. Ein geändertes `global.partOfPrefix` erfordert daher eine geplante Neuerstellung betroffener Deployments. Das kann Verfügbarkeit kosten. Eine neue Lane erzeugt neue Ressourcennamen. `namePrefix` allein trennt keine Pod-Selektoren: separate Releases benötigen auch eine unterscheidbare Release-/Lane-Identität.

## Gemeinsam genutzte Ressourcen

Mit `shared: true` entfällt die Lane im Namen und das Label `app.kubernetes.io/part-of`. Das Namenspräfix bleibt erhalten. `krypton-shared` erzeugt solche Ressourcen aus `configMaps`, `secrets` und `vault.secrets`.

**Für jeden gemeinsam genutzten Ressourcennamen darf es nur eine zuständige Application bzw. ein Helm-Release geben.** Mehrere Lanes referenzieren dieselben Objekte. Der Schalter `krypton-shared.enabled` regelt ihre Erzeugung; er setzt keine technische Sperre zwischen Applications.

| Betriebsart | Konfiguration |
| --- | --- |
| Lane nutzt vorhandene gemeinsame Ressourcen | `krypton-shared.enabled: false` (Standard) |
| Eine Lane verwaltet auch die gemeinsamen Ressourcen | `krypton-shared.enabled: true` |
| Eigene Application verwaltet nur gemeinsame Ressourcen | `values-shared-only.yaml` verwenden |

Banking und Auth können mit `sharedEnvFrom.configMaps` und `sharedEnvFrom.secrets` Instanzschlüssel referenzieren. Die Namensberechnung erfolgt mit `chart: krypton-shared` und `shared: true`. Das garantiert denselben Namen bei gleichen Präfixen, aber weder die Existenz noch die rechtzeitige Bereitstellung des Objekts. Sync-Waves koordinieren keine unabhängigen Applications.

Banking kann außerdem seine eigene ConfigMap mit `config.shared: true` ohne Lane erzeugen. Dann darf nur ein Bereitsteller `config.create: true` setzen; andere Lanes setzen `config.create: false` und verwenden dieselbe Referenz.

### NetworkPolicy

Die Standardvariante kann im Shared-Chart eine NetworkPolicy mit `podSelector: {}` erzeugen. Sie erlaubt eingehenden Verkehr aus demselben Namespace und aus den über Labels ausgewählten OpenShift-Ingress-Namespaces. `allowRouterHostNetwork` ergänzt den Host-Network-Namespace; `extraRules` ergänzt weitere Regeln.

Die Regel ist keine Garantie, dass externer Verkehr ausschließlich über Routes ankommt: Die Namespace-Freigaben sind breiter, weitere NetworkPolicies wirken additiv, und das Netzwerk-Plugin muss Policies unterstützen. Diese Policy enthält keine Egress-Regeln; andere Policies können ausgehenden Verkehr dennoch begrenzen. Siehe [Kubernetes NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

## Sync-Waves und Prune-Schutz

Für jeden Komponententyp wird zuerst `syncWaves.<component>` im Subchart ausgewertet, danach `global.syncWaves.<component>`. Der Subchart-Wert enthält bereits die Overrides aus dem Umbrella. `0` und negative Zahlen sind gültig.

`syncWaveOffset` wird zum gefundenen Wert addiert. Gibt es keinen Wert, gilt bei einem gesetzten Offset die Basis `0`; ohne Wave und ohne Offset wird keine Wave-Annotation erzeugt.

Waves und Offsets werden als dezimale Ganzzahlen geprüft: `"08"` ergibt `8`, `"010"` ergibt `10`. Eingabewerte und Summe müssen in den vorzeichenbehafteten 64-Bit-Bereich passen; ungültige Werte und Überläufe brechen das Rendern ab. Zahlen mit führenden Nullen und sehr große Zahlen in YAML als Strings angeben. Die Zahl `0` ist gültig; YAML-`null` ist kein Ersatz dafür.

| Subchart | Reihenfolge mit den Standardwerten |
| --- | --- |
| Banking | ServiceAccount `-2`, VaultStaticSecrets `-1`, ConfigMap `0`, Deployment/Service/PDB `1`, Route `3` |
| Auth | ServiceAccount `8`, Deployment `11` (Offset `10`) |

Offsets müssen anhand der tatsächlich verwendeten Bereiche gewählt werden. Für lokale Waves `-9..9` reichen Zehnerschritte nicht: Die Bereiche `-9..9` und `1..19` überlappen. Ein Abstand von mindestens `19` trennt diese Bereiche.

Waves bestimmen die Reihenfolge innerhalb einer Argo-CD-Application und Sync-Phase. Eine frühere VaultStaticSecret-Wave garantiert allein nicht, dass der Operator das Ziel-Secret bereits erzeugt hat. Dafür braucht es eine geeignete Zustandsprüfung bzw. einen expliziten Bereitschaftstest. Readiness-Probes bestimmen die Bereitschaft der Pods; Liveness-Probes steuern Neustarts. Siehe [Argo CD Sync-Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

`syncPrune.<component>` hat dieselbe Priorität wie `syncWaves`. `false` erzeugt `Prune=false`; `true` hebt einen geerbten Schutz auf. Die Schemas akzeptieren Booleans sowie die Strings `"true"` und `"false"`. Standardmäßig sind VaultStaticSecrets und die Banking-Route geschützt. `Prune=false` betrifft das Pruning beim Sync, nicht automatisch die kaskadierende Löschung einer Application. Die Slim-Variante unterstützt dafür zusätzlich `Delete=false`.

## Helper aufrufen

Helper erhalten ein Dictionary. `ctx` enthält den Kontext des Subcharts: außerhalb einer Schleife `.`, innerhalb einer `range`-Schleife den vorher gespeicherten Root-Kontext oder `$`.

```yaml
metadata:
  {{- include "krypton-lib.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

| Helper | Zweck / zusätzliche Argumente |
| --- | --- |
| `componentName` | Name; `component`, optional `instance`, `shared`, `chart` für Referenzen |
| `metadata` | kompletter Metadata-Block; Namensargumente und Annotation-Argumente |
| `labels` | Ressourcen-/Pod-Labels; optional `shared` |
| `selectorLabels` | drei Identitätslabels für Pod-Selektoren |
| `annotations` | Annotations; `component`, optional `extra`, `annotation`, `annotationsFrom` |
| `syncWave` / `syncOptions` | aufgelöste Argo-CD-Werte für `component` |
| `image` | Image-Referenz aus Values; optional eigener `image`-Block |
| `serviceAccountName` | erzeugter oder vorhandener ServiceAccount |
| `tplValue` | `value` als Template im Kontext `ctx` auswerten |
| `validateResourceNames` | eindeutige Namen in `configMaps`, `secrets`, `vault.secrets` prüfen; optional `shared` |

Annotations werden in dieser Reihenfolge zusammengeführt; spätere Einträge überschreiben frühere:

1. `<labelDomain>/source-chart`
2. `global.annotations`
3. `extra` (Map am Helper-Aufruf)
4. `annotation` (ein String `key=value`)
5. `annotationsFrom` (Punktpfad unter `.Values`, z. B. `route.annotations`)
6. konfigurierte Sync-Wave und Sync-Options

Alle resultierenden Werte werden in Strings umgewandelt. Ein fehlender `annotationsFrom`-Pfad trägt nichts bei; ein vorhandener skalarer Zielwert ist ein Fehler. Die beiden Argo-CD-Keys sollten über `syncWaves`/`syncPrune` konfiguriert werden. Ohne aufgelösten Wert bleibt eine direkt in einer Annotation-Map gesetzte Argo-CD-Annotation erhalten.

## Workloads konfigurieren

Die vollständigen Optionen stehen in den `values.yaml`-Dateien und Schemas der jeweiligen Subcharts. Nicht jede Option ist in jedem Subchart implementiert.

| Bereich | Verhalten |
| --- | --- |
| `image` | `registry/repository:tag`; `digest` hat Vorrang vor `tag`, ansonsten dient `Chart.appVersion` als Tag-Fallback |
| `global.imageRegistry` | überschreibt die Registry bei Subcharts, die den Image-Helper verwenden |
| `serviceAccount` | bei `create: true` eigener Account; mit `name` benennbar. Bei `create: false` vorhandener `name`, sonst `default` |
| Banking `vault.secrets` | ein VaultStaticSecret je Schlüssel; `authRef`, `mount`, `refreshAfter` je Eintrag überschreibbar; `envFrom: true` bindet das Ziel-Secret ein |
| Banking `config` | `create` steuert Erzeugung, `data` den Inhalt, `envFrom` Umgebungsvariablen, `mountPath` die Einbindung als Dateien |
| Banking `config.rollPodsOnChange` | Prüfsumme von `config.data` im Pod-Template löst bei Änderung einen Rollout aus; erfasst keine externen Shared-ConfigMaps oder Secret-Änderungen |
| `probes` | Readiness-, Liveness- und optional Startup-Probe |
| `extraEnv`, `extraEnvFrom` | zusätzliche Container-Umgebungsvariablen bzw. Referenzen |
| `podAnnotations` | zusätzliche Annotations am Pod-Template |
| `nodeSelector`, `tolerations`, `affinity` | Pod-Platzierung |
| Banking `autoscaling` | bei Aktivierung HPA statt festem `spec.replicas` |
| Banking `podDisruptionBudget` | optionaler Schutz bei freiwilligen Unterbrechungen |

Umgebungsvariablen ändern sich in laufenden Containern nicht. Eine ConfigMap als Verzeichnis wird zeitversetzt aktualisiert; die Anwendung muss die Dateien selbst neu einlesen. `rollPodsOnChange` deshalb nur abschalten, wenn diese Aktualisierung ausreicht.

## Charts erweitern und prüfen

Für ein einzelnes Subchart muss dessen Library-Abhängigkeit lokal gebaut werden:

```bash
helm dependency build charts/krypton-banking
helm template t charts/krypton-banking --set global.laneName=dev
```

Dabei entstehen `charts/krypton-banking/charts/` und gegebenenfalls `Chart.lock`. `.gitignore` verhindert nur das Committen, nicht das Laden durch Helm. Vor späteren Umbrella-Tests die erzeugten Library-Kopien entfernen oder eine frische Arbeitskopie verwenden, damit keine alte Helper-Version geladen wird.

Ein neues Subchart benötigt `Chart.yaml`, `values.yaml`, Templates und ein passendes `values.schema.json`. Zusätzlich:

1. Abhängigkeit auf `krypton-lib` mit `repository: file://../krypton-lib` deklarieren.
2. Subchart in der Umbrella-`Chart.yaml` mit `condition: krypton-<name>.enabled` registrieren und den Schalter in den Umbrella-Values setzen.
3. **Den neuen Subchart-Key auch im Umbrella-Schema unter `properties` ergänzen.** Sonst lehnt das strikte Schema ihn ab.
4. Metadata-/Selektor-Helper verwenden; bei Ressourcen-Maps die Namensprüfung ergänzen.
5. Neue Komponententypen in beiden Library-Katalogen ergänzen; bestehende Typen benötigen keinen neuen Eintrag. Typkürzel im Katalog dienen nur der Dokumentation.
6. `helm lint`, Render-Tests und die Regressionstests ausführen:

```bash
python tests/test_charts.py --helm helm
```

Das Umbrella und seine Anwendungs-/Shared-Subcharts haben Schemas; die Library hat keines. Unbekannte Komponenten-Keys werden beim Rendern von Ressourcen gegen den Katalog geprüft. Deaktivierte Charts ohne gerenderte Ressourcen durchlaufen diese Helper-Prüfung nicht.

## Argo CD

Für ein Repository mit dieser Verzeichnisstruktur lautet der Chart-Pfad `.`. URL und Git-Revision im Beispiel sind Platzhalter:

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
    path: .
    helm:
      parameters:
        - name: global.laneName
          value: release
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

Eine eigene Shared-Application verwendet denselben Pfad und `helm.valueFiles: [values-shared-only.yaml]`. Sie muss die gemeinsamen Ressourcen vor den konsumierenden Anwendungen bereitstellen. Die Helm-Version der eingesetzten Argo-CD-Installation separat prüfen; ein lokaler Helm-Test ersetzt keinen Test im Zielcluster.

Die [Slim-Variante](krypton-umbrella-slim/README.de.md) hat ein eigenes Umbrella und wird mit `path: krypton-umbrella-slim` bereitgestellt. Ihre Library konzentriert sich auf Metadaten und Selektorlabels; Image- und Workload-Konfiguration bleiben in den Subchart-Templates.
