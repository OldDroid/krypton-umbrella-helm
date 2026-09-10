# krypton-lib-slim

[English](README.md)

krypton-lib-slim ist ein Helm-**Library-Chart**. Es stellt benannte Templates für Ressourcennamen, Labels, Annotations und Argo-CD-Einstellungen bereit und erzeugt selbst keine Ressourcen. Das verwendende Chart enthält die Templates für Deployments, Container und andere Ressourcen.

## Abhängigkeit einbinden

Liegen `my-app` und `krypton-lib-slim` nebeneinander, wird die Abhängigkeit in `my-app/Chart.yaml` so eingetragen:

```yaml
apiVersion: v2
name: my-app
version: 0.1.0
dependencies:
  - name: krypton-lib-slim
    version: 0.1.0
    repository: file://../krypton-lib-slim
```

In der `values.yaml` **des verwendenden Charts** muss die Lane stehen:

```yaml
global:
  laneName: test
```

Im gemeinsamen übergeordneten Verzeichnis zuerst `helm dependency build my-app`, dann `helm template demo my-app` ausführen. Die `values.yaml` einer Library liefert dem Aufrufer keine Standardwerte. Die Library hat kein Values-Schema; das verwendende Chart sollte ein eigenes Schema bereitstellen. Die Helper prüfen die unten beschriebenen Fälle, aber nicht sämtliche Kubernetes-Regeln.

In diesem Repository lädt das Umbrella die Library bereits aus ihrem Verzeichnis. Ein Dependency-Build einzelner Subcharts erzeugt zusätzliche Kopien. Veraltete Kopien vor Umbrella-Tests aktualisieren oder entfernen: Helms benannte Templates teilen sich einen Namensraum über den gesamten Abhängigkeitsbaum.

## Helper aufrufen

Jeder öffentliche Helper erhält ein Dictionary. `ctx` ist der **Root-Kontext des aufrufenden Charts**; dessen Values enthalten bereits die Overrides aus dem Umbrella. `include` liefert Text: Für YAML-Blöcke `nindent`, für einzelne String-Felder `quote` verwenden.

```yaml
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" . "component" "deployment") | nindent 2 }}
```

Vor einer `range`- oder `with`-Anweisung den Root-Kontext speichern:

```yaml
{{- $root := . -}}
{{- range $key, $data := .Values.configMaps }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  {{- include "krypton-lib-slim.metadata" (dict "ctx" $root "component" "configMap" "instance" $key) | nindent 2 }}
data:
  {{- $data | toYaml | nindent 2 }}
{{- end }}
```

| Helper mit Präfix `krypton-lib-slim.` | Argumente zusätzlich zu `ctx` | Ergebnis |
| --- | --- | --- |
| `metadata` | `component`; optional `instance`, `shared`, `chart`, `extraLabels`, `extraAnnotations`, `annotation`, `annotationsFrom` | Inhalt von `metadata`: Name, Labels und Annotations |
| `componentName` | `component`; optional `instance`, `shared`, `chart` | Ressourcenname |
| `labels` | optional `shared`, `extraLabels` | Label-Map als YAML |
| `selectorLabels` | keine | Drei Pod-Identitätslabels als YAML-Strings |
| `annotations` | `component`; optional `extraAnnotations`, `annotation`, `annotationsFrom` | Annotation-Map als YAML |
| `syncWave`, `syncOptions` | `component` | Aufgelöster Wert als Text oder leerer String |
| `validateResourceNames` | optional `shared` | Keine Ausgabe; Fehler bei Namenskollisionen in unterstützten Ressourcen-Maps |
| `laneName`, `namePrefix`, `partOf`, `labelDomain`, `chart` | keine | Lane, Namenspräfix, Lane-Label, Annotation-Domain bzw. Chart-/Versionslabel |
| `componentCatalog` | keine | Zulässige Komponententypen als YAML-Map |
| `assertComponent` | `component`; optional `origin` | Keine Ausgabe; Fehler bei unbekanntem Typ |
| `validateComponentConfig` | keine | Prüft Komponentenschlüssel in lokalen/globalen Sync-Maps |


`component` bezeichnet einen Ressourcentyp, etwa `deployment` oder `secret`. Das Argument ist bei allen Helpern, die es verwenden, erforderlich und wird geprüft. **Es erscheint nicht im Ressourcennamen.** Die Groß-/Kleinschreibung der Typnamen muss dem Katalog entsprechen:

```text
buildConfig clusterRole clusterRoleBinding configMap
cronJob daemonSet deployment horizontalPodAutoscaler
imageStream ingress job networkPolicy
persistentVolumeClaim podDisruptionBudget podMonitor prometheusRule
role roleBinding route secret
service serviceAccount serviceMonitor statefulSet
vaultAuth vaultConnection vaultDynamicSecret vaultStaticSecret
```

Die Kürzel im Katalog dienen nur der Information. Ein bekannter, aber nicht verwendeter Typ hat keine Wirkung. Neue Typen in beiden Katalogen ergänzen. `syncInteger` ist ein interner Parser und nicht für direkte Aufrufe vorgesehen.

## Namen, Labels und Referenzen

Ressourcennamen folgen `[<namePrefix>-]<chart>-<lane>[-<instance>]`. `chart` verwendet standardmäßig `ctx.Chart.Name`; bei `shared: true` entfällt die Lane. `namePrefix` gilt auch für gemeinsame Ressourcen.

Die Instanznormalisierung fügt zwischen einem Kleinbuchstaben bzw. einer Ziffer und einem folgenden Großbuchstaben einen Bindestrich ein. Danach wird alles kleingeschrieben; Zeichen außerhalb von `[a-z0-9-]` werden durch `-` ersetzt. Deshalb ergeben `apiKey` und `api-key` beide `api-key`. Der gesamte Name darf höchstens 63 Zeichen lang sein. Anschließend wird aus Kompatibilitätsgründen ein abschließender Bindestrich entfernt. Das Ergebnis muss `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` entsprechen, sonst bricht das Rendern ab. Aus `abc_` wird beispielsweise `abc`; `abc__` hinterlässt noch einen Bindestrich und wird abgelehnt. Namen werden nicht stillschweigend gekürzt. Einzelne Ressourcentypen können strengere Regeln haben, etwa Services mit einer Ziffer am Namensanfang.

`validateResourceNames` muss ausdrücklich aufgerufen werden, zum Beispiel in `templates/validate.yaml`:

```yaml
{{- include "krypton-lib-slim.validateResourceNames" (dict "ctx" .) -}}
```

Verwenden die Ressourcen gemeinsame Namen, hier ebenfalls `shared: true` übergeben. Der Helper prüft `configMaps` separat und danach `secrets` zusammen mit `vault.secrets`. Der jeweilige Map-Schlüssel dient als `instance`. Eine ConfigMap und ein Secret dürfen denselben Namen haben. Andere Maps, Charts, Releases oder Clusterobjekte werden nicht geprüft; ein `chart`-Override ist nicht vorgesehen. Bei eigenen Namenskonventionen muss die Prüfung angepasst werden.

Für einen Verweis auf ein anderes Chart dessen Namen an `componentName` übergeben:

```yaml
name: {{ include "krypton-lib-slim.componentName" (dict "ctx" . "chart" "krypton-shared" "component" "configMap" "instance" "common" "shared" true) | quote }}
```

Erzeugung und Referenz müssen dieselben Präfixe, Chart-Namen, Instanzen und Shared-Einstellungen verwenden; bei Lane-Ressourcen auch dieselbe Lane. `chart` ändert nur den Namen. Labels und Annotations beschreiben weiterhin den Aufrufer. Die Helper prüfen weder Existenz noch Zuständigkeit: Für jede gemeinsame Ressource muss genau ein Release bzw. eine Application zuständig sein.

Reservierte Identitätslabels sind `app.kubernetes.io/name` = Name des aufrufenden Charts, `app.kubernetes.io/instance` = Helm-Release-Name und `app.kubernetes.io/part-of` = `[<partOfPrefix>-]<laneName>`. Das Label `instance` hat nichts mit dem gleichnamigen Argument für Ressourcennamen zu tun. Der zusammengesetzte `part-of`-Wert muss ein gültiges, nicht leeres Label mit höchstens 63 Zeichen sein. Shared-Labels lassen `part-of` weg; `selectorLabels` gibt es immer aus. Am zugehörigen Pod-Template deshalb Lane-Labels verwenden. Eine Änderung des Deployment-Selektors erfordert eine geplante Neuerstellung; `namePrefix` verändert Selektoren nicht.

## Values und Vorrangregeln

| Values-Pfad | Bedeutung / Standard |
| --- | --- |
| `global.laneName` | Erforderlich für Namen oder Labels mit Lane |
| `global.namePrefix` | Optionales Präfix für Ressourcennamen; standardmäßig leer |
| `global.partOfPrefix` | Optionales Präfix für das Lane-Label; standardmäßig leer |
| `global.labelDomain` | Domain für `<domain>/source-chart`; Standard `krypton.io` |
| `global.labels`, `global.annotations` | Zusätzliche Metadata-Maps |
| `global.syncWaves`, `syncWaves` | Waves je Komponente; ein lokaler Schlüssel hat Vorrang |
| `syncWaveOffset` | Wird zu jeder aufgelösten Wave addiert; Standard `0` |
| `global.syncOptions`, `syncOptions` | Sync-Optionen je Komponente; lokale Werte ersetzen globale |
| `labels`, `annotations` | Zusätzliche Maps des aufrufenden Subcharts |

Labels werden so zusammengeführt: Standard → `global.labels` → Subchart-`labels` → `extraLabels`. Danach werden die drei reservierten Identitätswerte erneut gesetzt. Eigene Maps können diese Werte somit nicht überschreiben. Für gemeinsame Ressourcen wird `part-of` nach dem Zusammenführen entfernt.

Annotations werden so zusammengeführt: erzeugtes source-chart → `global.annotations` → Subchart-`annotations` → `extraAnnotations` → `annotation` → `annotationsFrom` → **nicht leere** Ergebnisse aus `syncWave` und `syncOptions`. Spätere Quellen überschreiben frühere. Alle fertigen Label- und Annotation-Werte werden als Strings ausgegeben. Skalare Werte verwenden; verschachtelte Listen/Maps werden durch die Textumwandlung nicht zu sinnvoller Kubernetes-Metadata. Eigene Schlüssel und Label-Werte werden von der Library nicht vollständig validiert.

`annotation` akzeptiert einen String `key=value`, trennt am ersten `=` und entfernt äußere Leerzeichen von Schlüssel und Wert. Ein fehlendes `=` oder ein leerer Schlüssel führt zum Fehler. `annotationsFrom` ist ein Punktpfad relativ zu `ctx.Values`, zum Beispiel `route.annotations`:

| Ergebnis der Pfadauflösung | Verhalten |
| --- | --- |
| Fehlender Schlüssel oder skalarer Wert/Liste in einem Zwischenschritt | Fügt nichts hinzu |
| Erreichter Zielwert ist YAML-`null` | Fügt nichts hinzu |
| Erreichter Zielwert ist eine Map | Führt deren Einträge zusammen |
| Erreichter Zielwert ist ein skalarer Wert oder eine Liste | Bricht das Rendern ab |

Punkte trennen Pfadsegmente; Punkte innerhalb eines Schlüssels lassen sich so nicht adressieren. Helm kann einen auf `null` gesetzten Schlüssel bereits beim Zusammenführen der Values entfernen, bevor der Helper aufgerufen wird.

## Argo-CD-Einstellungen

Waves und Offsets akzeptieren Ganzzahlen oder Strings nach `^-?[0-9]+$`. Dezimalstrings mit führenden Nullen sind erlaubt: `"08"` bedeutet `8`, `"010"` bedeutet `10`. Solche Werte in YAML in Anführungszeichen setzen, damit der YAML-Parser sie nicht vorher anders interpretiert. Die Einzelwerte und ihre Summe müssen zwischen `-9223372036854775808` und `9223372036854775807` liegen. Ungültige Werte und Überläufe führen zum Fehler. Sehr große Ganzzahlen ebenfalls als Strings angeben, damit sie beim YAML-/JSON-Einlesen exakt erhalten bleiben.

Es gilt der erste vorhandene Schlüssel: zuerst lokales `syncWaves.<component>`, danach global. Die ausdrücklich gesetzte Zahl `0` überschreibt eine globale Wave; YAML-`null` ist nicht die Zahl null. Danach wird der lokale Offset addiert. Ohne Wave wird ein von null verschiedener Offset allein ausgegeben. Ohne Wave und bei Offset `0` liefert der Helper einen leeren String. Alle Instanzen eines Typs verwenden dieselbe Wave. Offsets müssen zu den tatsächlichen Bereichen passen: Lokale Waves `-9..9` benötigen mindestens `19` Abstand, damit sich die Bereiche nicht überlappen.

`syncOptions` akzeptiert eine Liste von Strings oder einen kommagetrennten String je Komponente. Lokale Werte ersetzen globale; Listen werden nicht zusammengeführt. `[]` oder `""` setzt das geerbte Helper-Ergebnis zurück. Ein direkt übergebenes `null` ergibt ebenfalls einen leeren String; nach Helms Values-Merge kann der Schlüssel allerdings fehlen. Ungültige Typen führen zum Fehler. Beispiel: `syncOptions: {route: ["Prune=false", "Delete=false"]}`.

Ein leeres Helper-Ergebnis **löscht keine** direkt gesetzte Annotation `argocd.argoproj.io/sync-wave` oder `argocd.argoproj.io/sync-options` aus einer Annotation-Map. Das Zurücksetzen geerbter Helper-Optionen entfernt also keine separat gesetzte Annotation. Diese Schlüssel einheitlich über die Sync-Einstellungen konfigurieren.

Sync-Waves ordnen Ressourcen innerhalb einer Argo-CD-Application und Phase. Sie koordinieren keine getrennten Applications und garantieren nicht, dass ein Operator ein Ziel-Secret bereits erzeugt hat. `Prune=false` steuert das Pruning beim Sync; für Schutz beim Löschen einer Application gibt es die separate Option `Delete=false`. Siehe die offiziellen Dokumentationen zu [Sync-Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) und [Sync-Optionen](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/).


## Kompatibilität und Prüfung

Diese Überarbeitung ersetzt stillschweigende Namenskürzung durch eine Fehlermeldung und prüft zusammengesetzte Lane-Labels, dezimale Waves sowie Komponentenargumente. Gültige Namen, die innerhalb von 63 Zeichen aufgebaut werden, bleiben unverändert. Konfigurationen, die bisher von der Kürzung abhingen, müssen ihre Eingaben vor dem Upgrade verkürzen. Die resultierenden Namen mit den bereitgestellten Ressourcen vergleichen und erforderliche Umbenennungen planen. Das ist eine Verhaltensänderung, keine automatische Migration. Selektorwerte bleiben nun auch für Werte wie `"123"` Strings.

Unterschied zur großen Library: Slim bietet lokale `labels`/`annotations`, `extraLabels`, `extraAnnotations` und allgemeine `syncOptions`. Die große Library nennt das Annotation-Argument `extra` und verwendet `syncPrune`. Ihre Helper `image`, `serviceAccountName` und `tplValue` sind in Slim nicht vorhanden. Ein Wechsel erfordert daher Anpassungen an den Aufrufen und Values.

Im Repository-Stamm `python tests/test_charts.py --helm helm` ausführen. Die Tests prüfen beide Libraries mit echten Helm-Renderläufen, einschließlich Grenzwerten und fehlerhaften Eingaben. Das verwendende Chart zusätzlich mit der Helm-Version des Bereitstellungssystems rendern. Diese Prüfungen erfassen weder verfügbare CRDs noch Admission-Regeln im Zielcluster.
