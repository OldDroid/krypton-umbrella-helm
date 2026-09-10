# krypton-umbrella-slim

Die Slim-Variante ist ein eigenständiges Umbrella-Chart. Ihre Library `krypton-lib-slim` vereinheitlicht Namen, Labels, Annotations und die Argo-CD-Sync-Reihenfolge. Zusätzlich stellt sie Pod-Selektorlabels und eine Namensprüfung bereit. Images, Probes, Volumes und andere Workload-Einstellungen bleiben in den Templates der Subcharts.

[English](README.md) · [Library-Referenz](charts/krypton-lib-slim/README.de.md) · [Grundlagen der Standardvariante](../README.de.md) · [Konfigurationsbeispiele](../docs/slim.html)

**Änderung der Library:** Überlange Namen werden jetzt abgelehnt. Bestehende Konfigurationen, die auf Kürzung angewiesen waren, müssen vor einem Upgrade angepasst und mit den bereitgestellten Ressourcennamen verglichen werden. Auch `partOfPrefix` und `laneName` zusammen dürfen als Label höchstens 63 Zeichen ergeben. Details und Grenzen der Prüfung stehen in der Library-Referenz.

## Aufbau und Einstieg

```text
krypton-umbrella-slim/
├── Chart.yaml
├── values.yaml
├── values.schema.json
├── values-shared-only.yaml
└── charts/
    ├── krypton-lib-slim/       # gemeinsame Metadata- und Selektor-Helper
    ├── krypton-payments/       # ServiceAccount, ConfigMaps, Secrets,
    │                          # VaultStaticSecrets, Deployment, Service, Route
    ├── krypton-notifier/       # ConfigMap, Deployment und Service
    └── krypton-shared/         # gemeinsame ConfigMaps, Secrets, VaultStaticSecrets
```

Alle Befehle auf dieser Seite werden **im Stammverzeichnis des Repositorys**, eine Ebene oberhalb dieses Charts, ausgeführt:

```bash
helm lint krypton-umbrella-slim
helm template krypton krypton-umbrella-slim
helm template krypton krypton-umbrella-slim --set global.laneName=test
```

Eine **Lane** ist eine Bereitstellungsumgebung wie `release` oder `test`. Der Lane-Name ändert Namen und Lane-Labels; Ressourcenlimits oder Replikazahlen benötigen eigene Overrides. **Rendern** erzeugt YAML, legt aber keine Ressourcen im Cluster an.

Die Values enthalten Demo-Images, Beispiel-Hosts und Beispiel-Secrets. Für eine Installation müssen diese angepasst werden. OpenShift Routes, der Vault Secrets Operator und eine passende VaultAuth-Konfiguration sind Voraussetzungen der Beispielanwendungen. Payments erwartet standardmäßig die gemeinsamen Ressourcen `krypton-shared-common` und `krypton-shared-gateway`.

## Helper verwenden

Jeder Helper erhält ein Dictionary. `ctx` ist der Subchart-Kontext: `.` außerhalb einer Schleife, der gespeicherte Root-Kontext oder `$` innerhalb von `range`.

| Helper (Präfix `krypton-lib-slim.`) | Argumente zusätzlich zu `ctx` | Ergebnis |
| --- | --- | --- |
| `metadata` | `component`; optional `instance`, `shared`, `chart`, `extraLabels`, `extraAnnotations`, `annotation`, `annotationsFrom` | Name, Labels und Annotations |
| `componentName` | `component`; optional `instance`, `shared`, `chart` | Ressourcenname, auch für Referenzen |
| `labels` | optional `shared`, `extraLabels` | Ressourcen-/Pod-Labels |
| `selectorLabels` | keine | drei Pod-Identitätslabels |
| `annotations` | `component`; optional `extraAnnotations`, `annotation`, `annotationsFrom` | zusammengeführte Annotations |
| `syncWave` / `syncOptions` | `component` | aufgelöster Wert oder leerer String |
| `validateResourceNames` | optional `shared` | bricht bei kollidierenden Namen in Ressourcen-Maps ab |

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

## Namen, Instanzen und Referenzen

Das Namensschema lautet `[<namePrefix>-]<subchart>-<lane>[-<instance>]`. Der Ressourcentyp wird nicht angehängt; `component` ist trotzdem erforderlich, um den Typ zu prüfen und seine Sync-Einstellungen auszuwählen.

```text
krypton-payments-release             # Deployment, Service, Route, ServiceAccount
krypton-payments-release-app         # ConfigMap und VaultStaticSecret
krypton-payments-release-logging     # weitere ConfigMap
krypton-payments-release-smtp        # direkt erzeugtes Secret
krypton-payments-release-database    # VaultStaticSecret und sein Ziel-Secret
```

`instance` unterscheidet mehrere Ressourcen desselben Typs. Die Helper normalisieren Instanzen und lehnen Namen mit mehr als 63 Zeichen oder ungültigem Format ab. Verschiedene Eingaben können dadurch denselben Namen ergeben, etwa `apiKey` und `api-key`. Payments und Shared prüfen die fertigen Namen ihrer ConfigMaps und Secrets. Direkte Secrets und von Vault erzeugte Secrets teilen sich dabei denselben Namensraum.

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

Referenzen verwenden denselben Namens-Helper. Für ein Objekt des Shared-Charts wird dessen Chart-Name ausdrücklich angegeben:

```yaml
- secretRef:
    name: {{ include "krypton-lib-slim.componentName" (dict "ctx" $ "chart" "krypton-shared" "component" "secret" "instance" "gateway" "shared" true) }}
```

## Gemeinsame Ressourcen

`shared: true` lässt die Lane im Namen und das Label `app.kubernetes.io/part-of` weg. `global.namePrefix` bleibt wirksam. Pro gemeinsamem Ressourcennamen darf nur eine Application bzw. ein Helm-Release die Erzeugung übernehmen; andere Applications referenzieren das Objekt.

| Betriebsart | Einstellung |
| --- | --- |
| gemeinsame Objekte nur nutzen | `krypton-shared.enabled: false` (Standard) |
| eine Lane erzeugt auch die gemeinsamen Objekte | `krypton-shared.enabled: true` |
| separate Shared-Application | Overlay `values-shared-only.yaml` |

```bash
helm template krypton-shared krypton-umbrella-slim -f krypton-umbrella-slim/values-shared-only.yaml
helm template krypton krypton-umbrella-slim --set krypton-shared.enabled=true
```

Payments importiert Schlüssel aus `sharedEnvFrom.configMaps` und `sharedEnvFrom.secrets` als Container-Umgebungsvariablen. Der Helper berechnet den Namen, prüft aber nicht die Existenz. Die Shared-Application muss benötigte Objekte vor den Anwendungen bereitstellen; Waves koordinieren keine separaten Applications. Anders als die Standardvariante enthält Slim keine Shared-NetworkPolicy.

## Labels und Annotations

Label-Reihenfolge: Standardwerte → `global.labels` → Subchart-`labels` → `extraLabels`. Danach setzt die Library die reservierten Identitätslabels `app.kubernetes.io/name`, `app.kubernetes.io/instance` und `app.kubernetes.io/part-of`. Sie sind nicht frei überschreibbar, damit Pod-Labels und Selektoren zusammenpassen; bei Shared-Objekten entfällt `part-of`.

Der `instance`-Labelwert ist der Helm-Release-Name. Argo CD verwendet dafür standardmäßig den Application-Namen, sofern `helm.releaseName` ihn nicht überschreibt. Das Helper-Argument `instance` bezeichnet dagegen eine einzelne Ressource innerhalb des Subcharts.

Annotation-Reihenfolge: `<labelDomain>/source-chart` → `global.annotations` → Subchart-`annotations` → `extraAnnotations` → `annotation` → `annotationsFrom` → konfigurierte Argo-CD-Werte. Alle resultierenden Werte werden in Strings umgewandelt.

- `extraAnnotations`: Map direkt am Helper-Aufruf.
- `annotation`: einzelner String `key=value`.
- `annotationsFrom`: Punktpfad unter `.Values`, z. B. `route.annotations`. Ein fehlender Pfad wird ignoriert, ein vorhandener skalarer Zielwert ist ein Fehler.

Eine konfigurierte Wave oder Sync-Option überschreibt den entsprechenden direkt gesetzten Argo-CD-Annotationswert. Ohne aufgelösten Wert bleibt eine direkte Annotation erhalten. Für einheitliches Verhalten diese Keys über `syncWaves` und `syncOptions` konfigurieren.

## Waves und Sync-Options

Für jeden Komponententyp gilt: Subchart-Wert einschließlich Umbrella-Overrides vor globalem Wert. `syncWaveOffset` wird addiert; eine nicht konfigurierte Wave zählt dafür als `0`. Alle Instanzen eines Typs verwenden dieselbe Wave.

Waves und Offsets werden als dezimale Ganzzahlen geprüft: `"08"` ergibt `8`, `"010"` ergibt `10`. Eingabewerte und Summe müssen in den vorzeichenbehafteten 64-Bit-Bereich passen; ungültige Werte und Überläufe brechen das Rendern ab. Zahlen mit führenden Nullen und sehr große Zahlen in YAML als Strings angeben. Die Zahl `0` ist gültig; YAML-`null` ist kein Ersatz dafür.

Mit den Standardwerten belegt Payments `-2..3`. Notifier hat Offset `10`: ConfigMap `10`, Deployment und Service `11`. Diese Bereiche überlappen nicht. Für lokale Waves `-9..9` wären hingegen mindestens `19` Abstand nötig; Zehnerschritte reichen nicht allgemein aus.

Eine frühere VaultStaticSecret-Wave allein garantiert kein fertiges Ziel-Secret. Die Bereitstellung durch den Operator braucht eine geeignete Zustandsprüfung. Waves gelten innerhalb einer Application und Sync-Phase; siehe [Argo CD Sync-Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

`syncOptions.<component>` akzeptiert eine Liste oder einen kommagetrennten String. Der lokale Wert ersetzt den globalen vollständig; `[]` hebt eine geerbte Liste auf.

```yaml
global:
  syncOptions:
    vaultStaticSecret: ["Prune=false"]
krypton-payments:
  syncOptions:
    route: ["Prune=false", "Delete=false"]
    vaultStaticSecret: []
```

`Prune=false` verhindert das Entfernen beim Sync-Pruning. `Delete=false` schützt zusätzlich bei der kaskadierenden Löschung einer Argo-CD-Application. Weitere Optionen und ihre Auswirkungen stehen in der [Argo-CD-Referenz](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/).

## Values und Validierung

| Key | Bedeutung |
| --- | --- |
| `global.laneName` | im Umbrella erforderlich; Standard `release` |
| `global.namePrefix` | optionales Präfix aller Ressourcennamen |
| `global.partOfPrefix` | optionales Präfix des Lane-Labels; Teil unveränderlicher Deployment-Selektoren |
| `global.labelDomain` | Domain der `source-chart`-Annotation, Standard `krypton.io` |
| `global.labels`, `global.annotations` | gemeinsame Metadata-Werte |
| `global.syncWaves`, `global.syncOptions` | Standardwerte je Komponententyp |
| `labels`, `annotations` | zusätzliche Werte je Subchart |
| `syncWaves`, `syncOptions` | Overrides je Subchart und Komponententyp |
| `syncWaveOffset` | Verschiebung aller Waves des Subcharts |
| `<subchart>.enabled` | aktiviert die Abhängigkeit im Umbrella |

Das Umbrella-Schema prüft globale und Library-bezogene Subchart-Werte. Die Slim-Subcharts haben keine eigenen Schemas; andere Werte wie `replicaCount` werden dort nicht validiert. Beim eigenständigen Rendern eines Subcharts greift das Umbrella-Schema nicht. Unbekannte Komponenten-Keys werden geprüft, sobald Ressourcen die Metadata-Helper aufrufen.

`partOfPrefix` bei bestehenden Deployments nur mit einem Plan zur Neuerstellung ändern. `namePrefix` trennt Ressourcennamen, aber keine Pod-Selektoren. Die ausführlichen Hinweise dazu stehen in der [Standarddokumentation](../README.de.md).

## Ein Subchart erweitern oder hinzufügen

```bash
helm dependency build krypton-umbrella-slim/charts/krypton-payments
helm template t krypton-umbrella-slim/charts/krypton-payments --set global.laneName=dev
```

Der erste Befehl kopiert die Library als Abhängigkeit ins Subchart. Erzeugte `charts/`-Kopien und `Chart.lock` sind zwar gitignored, können aber trotzdem von Helm geladen werden. Vor Umbrella-Tests alte Library-Kopien entfernen oder eine frische Arbeitskopie verwenden.

Für ein neues Subchart:

1. `Chart.yaml`, `values.yaml` und Templates anlegen; Library mit `file://../krypton-lib-slim` deklarieren.
2. Abhängigkeit mit `condition: krypton-<name>.enabled` im Umbrella registrieren und den Values-Schalter setzen.
3. Im Umbrella-Schema unter `properties` ergänzen: `"krypton-<name>": { "$ref": "#/definitions/subchartBlock" }`.
4. Metadata-/Selektor-Helper verwenden und bei Ressourcen-Maps `validateResourceNames` aufrufen. Neue Komponententypen in beiden Library-Katalogen ergänzen.
5. Eigenes Subchart-Schema ergänzen, wenn auch Workload-Werte geprüft werden sollen. Lint, Render-Tests und `python tests/test_charts.py --helm helm` ausführen.

## Argo CD

Das Application-Beispiel der [Standardvariante](../README.de.md) mit `spec.source.path: krypton-umbrella-slim` und einem eigenen Application-Namen verwenden. Für eine separate Shared-Application zusätzlich `helm.valueFiles: [values-shared-only.yaml]` setzen. Dieser Dateipfad ist relativ zum Chart-Verzeichnis, nicht zum Repository-Stamm.

Slim wird durch `.helmignore` aus dem Standardchart ausgeschlossen. Die Helm-Version der Argo-CD-Installation separat prüfen; lokale Render-Tests prüfen weder Cluster-APIs noch Vault-Zugriff oder die Bereitschaft der Anwendungen.
