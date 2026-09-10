"""Render regressions; Python standard library and Helm only.

Run from any directory: python tests/test_charts.py --helm /path/to/helm
Tests use temporary chart copies, never cluster access or the source checkout.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--helm', default='helm')
args, remaining = parser.parse_known_args()
HELM = shutil.which(args.helm) or str(Path(args.helm).resolve())
ROOT = Path(__file__).resolve().parents[1]


class ChartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='krypton-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'chart'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('.git', '__pycache__'))

    def run_helm(self, *arguments, ok=True):
        p = subprocess.run([HELM, *map(str, arguments)], capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(p.returncode == 0, ok, p.stdout + p.stderr)
        return p.stdout + p.stderr

    def render(self, slim=False, values=None, ok=True):
        chart = self.root / 'krypton-umbrella-slim' if slim else self.root
        options = []
        if values is not None:
            f = Path(self.temp.name) / 'values.json'
            f.write_text(json.dumps(values), encoding='utf-8')
            options = ['-f', f]
        return self.run_helm('template', 'regression', chart, *options, ok=ok)

    def helper(self, slim, body, ok=True):
        """Render a real Helm fixture; helpers serialize their result as JSON."""
        chart = self.root / 'krypton-umbrella-slim' if slim else self.root
        lib = 'krypton-lib-slim' if slim else 'krypton-lib'
        fixture = '''{{- $ctx := dict "Chart" (dict "Name" "example" "Version" "1.0.0" "AppVersion" "1.0") "Release" (dict "Name" "release" "Service" "Helm") "Values" (dict "global" (dict "laneName" "test")) -}}
''' + body.replace('LIB', lib) + '''
apiVersion: v1
kind: ConfigMap
metadata:
  name: helper-result
data:
  result: {{ $result | toJson | quote }}
'''
        fixture_path = chart / 'templates/regression.yaml'
        fixture_path.write_text(fixture, encoding='utf-8')
        try:
            out = self.run_helm('template', 'regression', chart, '--show-only', 'templates/regression.yaml', ok=ok)
        finally:
            fixture_path.unlink()
        if not ok:
            return out
        match = re.search(r'^  result: (.+)$', out, re.M)
        self.assertIsNotNone(match, out)
        return json.loads(json.loads(match[1]))

    def test_lint_and_default_modes(self):
        for slim in [False, True]:
            chart = self.root / 'krypton-umbrella-slim' if slim else self.root
            self.run_helm('lint', chart)
            for values in [{}, {'global': {'laneName': 'test'}}, {'krypton-shared': {'enabled': True}}]:
                with self.subTest(slim=slim, values=values):
                    self.assertIn('kind: Deployment', self.render(slim, values))
            output = self.run_helm('template', 'regression', chart, '-f', chart / 'values-shared-only.yaml')
            self.assertNotIn('kind: Deployment', output)
            self.assertIn('name: krypton-shared-common', output)

    def test_reserved_labels_and_shared_omission(self):
        for slim in [False, True]:
            with self.subTest(slim=slim):
                result = self.helper(slim, '''{{- $custom := dict "app.kubernetes.io/name" "wrong" "app.kubernetes.io/instance" "wrong" "app.kubernetes.io/part-of" "wrong" "team" "platform" -}}
{{- $_ := set $ctx.Values.global "labels" $custom -}}
{{- $_ := set $ctx.Values "labels" $custom -}}
{{- $labels := include "LIB.labels" (dict "ctx" $ctx "extraLabels" $custom) | fromYaml -}}
{{- $selector := include "LIB.selectorLabels" (dict "ctx" $ctx) | fromYaml -}}
{{- $shared := include "LIB.labels" (dict "ctx" $ctx "shared" true "extraLabels" $custom) | fromYaml -}}
{{- $result := dict "labels" $labels "selector" $selector "shared" $shared -}}''')
                for key, value in result['selector'].items():
                    self.assertEqual(result['labels'][key], value)
                self.assertEqual(result['labels']['team'], 'platform')
                self.assertNotIn('app.kubernetes.io/part-of', result['shared'])

    def test_metadata_scalar_values_are_strings(self):
        for slim in [False, True]:
            with self.subTest(slim=slim):
                result = self.helper(slim, '''{{- $_ := set $ctx.Values.global "annotations" (dict "global-number" 42) -}}
{{- $_ := set $ctx.Values.global "labels" (dict "number" 42 "flag" true) -}}
{{- $extra := dict "count" 7 "enabled" false -}}
{{- $annotations := include "LIB.annotations" (dict "ctx" $ctx "component" "deployment" "extra" $extra "extraAnnotations" $extra) | fromYaml -}}
{{- $labels := include "LIB.labels" (dict "ctx" $ctx) | fromYaml -}}
{{- $result := dict "annotations" $annotations "labels" $labels -}}''')
                self.assertEqual(result['annotations']['global-number'], '42')
                self.assertEqual(result['annotations']['count'], '7')
                self.assertEqual(result['annotations']['enabled'], 'false')
                self.assertEqual(result['labels']['number'], '42')
                self.assertEqual(result['labels']['flag'], 'true')

    def test_sync_precedence_zero_negative_and_empty_options(self):
        for slim in [False, True]:
            with self.subTest(slim=slim):
                result = self.helper(slim, '''{{- $_ := set $ctx.Values.global "syncWaves" (dict "deployment" 8) -}}
{{- $_ := set $ctx.Values "syncWaves" (dict "deployment" 0 "service" -2) -}}
{{- $_ := set $ctx.Values "syncWaveOffset" 10 -}}
{{- $_ := set $ctx.Values.global "syncPrune" (dict "route" false) -}}
{{- $_ := set $ctx.Values "syncPrune" (dict "route" true) -}}
{{- $_ := set $ctx.Values.global "syncOptions" (dict "route" (list "Prune=false")) -}}
{{- $_ := set $ctx.Values "syncOptions" (dict "route" (list)) -}}
{{- $result := dict "zero" (include "LIB.syncWave" (dict "ctx" $ctx "component" "deployment")) "negative" (include "LIB.syncWave" (dict "ctx" $ctx "component" "service")) "implicit" (include "LIB.syncWave" (dict "ctx" $ctx "component" "job")) "options" (include "LIB.syncOptions" (dict "ctx" $ctx "component" "route")) -}}''')
                self.assertEqual(result, {'zero': '10', 'negative': '8', 'implicit': '10', 'options': ''})

    def test_normalized_secret_collisions(self):
        for slim, chart in [(False, 'krypton-shared'), (True, 'krypton-shared'), (True, 'krypton-payments')]:
            for second in ['apiKey', 'api-key']:
                with self.subTest(slim=slim, chart=chart, second=second):
                    values = {chart: {'enabled': True, 'secrets': {'apiKey': {'TOKEN': 'demo'}}, 'vault': {'secrets': {second: {'path': 'demo/path'}}}}}
                    self.assertIn('same resource name', self.render(slim, values, ok=False))

    def test_configmap_and_vault_internal_collisions(self):
        for slim, chart in [(False, 'krypton-shared'), (True, 'krypton-shared'), (True, 'krypton-payments')]:
            with self.subTest(slim=slim, chart=chart):
                values = {chart: {'enabled': True, 'configMaps': {'apiKey': {'X': '1'}, 'api-key': {'Y': '2'}}}}
                self.assertIn('same resource name', self.render(slim, values, ok=False))
        for slim, chart in [(False, 'krypton-banking'), (True, 'krypton-payments')]:
            with self.subTest(slim=slim, chart=chart):
                values = {chart: {'vault': {'secrets': {'apiKey': {'path': 'one'}, 'apiKEY': {'path': 'two'}}}}}
                self.assertIn('same resource name', self.render(slim, values, ok=False))

    def test_overlong_names_are_rejected_before_truncation(self):
        for slim in [False, True]:
            with self.subTest(slim=slim):
                prefix = 'a' * 70
                values = {'krypton-shared': {'enabled': True, 'secrets': {prefix+'x': {'X': '1'}, prefix+'y': {'Y': '2'}}}}
                self.assertIn('exceeds 63 characters', self.render(slim, values, ok=False))

    def test_decimal_waves_and_offsets(self):
        cases = [('08', '0', '8'), ('010', '-08', '2'), ('-08', '010', '2'),
                 ('-000', '000', '0'), (0, -2, '-2'), (8, 2, '10'),
                 ('9223372036854775807', '0', '9223372036854775807'),
                 ('-9223372036854775808', '0', '-9223372036854775808'),
                 ('9223372036854775807', '-9223372036854775808', '-1')]
        for slim in [False, True]:
            for wave, offset, expected in cases:
                with self.subTest(slim=slim, wave=wave, offset=offset):
                    result = self.helper(slim, '''{{- $_ := set $ctx.Values "syncWaves" (dict "deployment" WAVE) -}}
{{- $_ := set $ctx.Values "syncWaveOffset" OFFSET -}}
{{- $result := include "LIB.syncWave" (dict "ctx" $ctx "component" "deployment") -}}'''.replace('WAVE', json.dumps(wave)).replace('OFFSET', json.dumps(offset)))
                    self.assertEqual(result, expected)
            result = self.helper(slim, '''{{- $_ := set $ctx.Values.global "syncWaves" (dict "deployment" "08") -}}
{{- $result := include "LIB.syncWave" (dict "ctx" $ctx "component" "deployment") -}}''')
            self.assertEqual(result, '8')
            app = 'krypton-payments' if slim else 'krypton-banking'
            self.assertIn('argocd.argoproj.io/sync-wave: "8"', self.render(slim, {app: {'syncWaves': {'deployment': '08'}}}))

    def test_invalid_waves_offsets_and_overflow(self):
        cases = [('bogus', '0', 'decimal integer'), ('1.5', '0', 'decimal integer'),
                 (False, '0', 'decimal integer'), ('0', False, 'decimal integer'),
                 ('0', 'bogus', 'decimal integer'), ('0', '0x10', 'decimal integer'),
                 ('9223372036854775808', '0', 'signed 64-bit range'),
                 ('-9223372036854775809', '0', 'signed 64-bit range'),
                 ('0', '9223372036854775808', 'signed 64-bit range'),
                 ('9223372036854775807', '1', 'wave plus syncWaveOffset'),
                 ('-9223372036854775808', '-1', 'wave plus syncWaveOffset')]
        for slim in [False, True]:
            for wave, offset, error in cases:
                with self.subTest(slim=slim, wave=wave, offset=offset):
                    result = self.helper(slim, '''{{- $_ := set $ctx.Values "syncWaves" (dict "deployment" WAVE) -}}
{{- $_ := set $ctx.Values "syncWaveOffset" OFFSET -}}
{{- $result := include "LIB.syncWave" (dict "ctx" $ctx "component" "deployment") -}}'''.replace('WAVE', json.dumps(wave)).replace('OFFSET', json.dumps(offset)), ok=False)
                    self.assertIn(error, result)

    def test_selector_values_remain_strings(self):
        for slim in [False, True]:
            for value in ['123', 'true', 'null', '1e3']:
                with self.subTest(slim=slim, value=value):
                    result = self.helper(slim, '''{{- $_ := set $ctx.Values.global "laneName" VALUE -}}
{{- $_ := set $ctx.Chart "Name" VALUE -}}
{{- $_ := set $ctx.Release "Name" VALUE -}}
{{- $result := dict "labels" (include "LIB.labels" (dict "ctx" $ctx) | fromYaml) "selector" (include "LIB.selectorLabels" (dict "ctx" $ctx) | fromYaml) -}}'''.replace('VALUE', json.dumps(value)))
                    for key, actual in result['selector'].items():
                        self.assertIsInstance(actual, str)
                        self.assertEqual(actual, value)
                        self.assertEqual(result['labels'][key], actual)

    def test_name_boundaries_and_normalization(self):
        for slim in [False, True]:
            for instance, expected in [('apiKey', 'example-test-api-key'), ('abc_', 'example-test-abc'),
                                       ('a' * 50, 'example-test-' + 'a' * 50)]:
                with self.subTest(slim=slim, instance=instance):
                    result = self.helper(slim, '{{- $result := include "LIB.componentName" (dict "ctx" $ctx "component" "secret" "instance" INSTANCE) -}}'.replace('INSTANCE', json.dumps(instance)))
                    self.assertEqual(result, expected)
            for instance, error in [('a' * 51, 'exceeds 63 characters'), ('abc__', 'invalid resource name'), ('__', 'invalid resource name')]:
                with self.subTest(slim=slim, instance=instance):
                    result = self.helper(slim, '{{- $result := include "LIB.componentName" (dict "ctx" $ctx "component" "secret" "instance" INSTANCE) -}}'.replace('INSTANCE', json.dumps(instance)), ok=False)
                    self.assertIn(error, result)
            # Earlier truncation removed the lane's distinguishing final character.
            app = 'krypton-payments' if slim else 'krypton-banking'
            for suffix in ['x', 'y']:
                values = {'global': {'namePrefix': 'p' * 32, 'laneName': 'a' * 30 + suffix}, app: {'enabled': False}}
                self.assertIn('exceeds 63 characters', self.render(slim, values, ok=False))
            values = {'krypton-shared': {'enabled': True, 'configMaps': {'abc__': {'X': 'demo'}}}}
            self.assertIn('invalid resource name', self.render(slim, values, ok=False))

    def test_composed_part_of_label_validation(self):
        for slim in [False, True]:
            result = self.helper(slim, '''{{- $_ := set $ctx.Values.global "laneName" (repeat 31 "a") -}}
{{- $_ := set $ctx.Values.global "partOfPrefix" (repeat 31 "p") -}}
{{- $result := include "LIB.partOf" (dict "ctx" $ctx) -}}''')
            self.assertEqual(len(result), 63)
            result = self.helper(slim, '''{{- $_ := set $ctx.Values.global "partOfPrefix" "bad/label" -}}
{{- $result := include "LIB.partOf" (dict "ctx" $ctx) -}}''', ok=False)
            self.assertIn('invalid label value', result)
            values = {'global': {'laneName': 'a' * 32, 'partOfPrefix': 'p' * 32}}
            self.assertIn('invalid label value', self.render(slim, values, ok=False))

    def test_direct_helpers_reject_unknown_components(self):
        for slim in [False, True]:
            for helper in ['componentName', 'annotations', 'syncWave', 'syncOptions']:
                with self.subTest(slim=slim, helper=helper):
                    result = self.helper(slim, '{{- $result := include "LIB.HELPER" (dict "ctx" $ctx "component" "rout") -}}'.replace('HELPER', helper), ok=False)
                    self.assertIn('unknown component type "rout"', result)

    def test_image_tag_fallback_and_digest(self):
        cases = [('""', '""', '""', None), ('""', '""', '"2.0"', 'example/app:2.0'),
                 ('"3.0"', '""', '"2.0"', 'example/app:3.0'),
                 ('"3.0"', '"sha256:abc"', '""', 'example/app@sha256:abc')]
        for tag, digest, app_version, expected in cases:
            with self.subTest(tag=tag, digest=digest, app_version=app_version):
                result = self.helper(False, '''{{- $_ := set $ctx.Chart "AppVersion" APP_VERSION -}}
{{- $_ := set $ctx.Values "image" (dict "repository" "example/app" "tag" TAG "digest" DIGEST) -}}
{{- $result := include "LIB.image" (dict "ctx" $ctx) -}}'''.replace('APP_VERSION', app_version).replace('TAG', tag).replace('DIGEST', digest), ok=expected is not None)
                if expected is None:
                    self.assertIn('set image.tag, image.digest or Chart.appVersion', result)
                else:
                    self.assertEqual(result, expected)

    def test_explicit_service_account_name_needs_no_generated_fallback(self):
        for create in [True, False]:
            with self.subTest(create=create):
                result = self.helper(False, '''{{- $_ := unset $ctx.Values.global "laneName" -}}
{{- $_ := set $ctx.Values "serviceAccount" (dict "create" CREATE "name" "existing-account") -}}
{{- $result := include "LIB.serviceAccountName" (dict "ctx" $ctx) -}}'''.replace('CREATE', json.dumps(create)))
                self.assertEqual(result, 'existing-account')

    def test_distinct_resource_kinds_may_share_name(self):
        for slim in [False, True]:
            with self.subTest(slim=slim):
                values = {'krypton-shared': {'enabled': True, 'configMaps': {'custom': {'X': '1'}}, 'secrets': {'custom': {'Y': '2'}}}}
                self.assertGreaterEqual(self.render(slim, values).count('name: krypton-shared-custom'), 2)

    def test_unknown_component_is_rejected(self):
        for slim in [False, True]:
            with self.subTest(slim=slim):
                self.assertIn('unknown component', self.render(slim, {'global': {'syncWaves': {'rout': 3}}}, ok=False))


if __name__ == '__main__':
    unittest.main(argv=[__file__, *remaining])
