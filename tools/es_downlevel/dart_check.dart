// Run the REAL Dart implementation of the downleveler (the very file the app
// ships: lib/webview/video/js_downlevel.dart) over the corpus and the fixtures,
// and dump the results plus a machine-readable report.
//
// All assertions live in run_checks.js - this script only produces evidence.
//
//   dart tools/es_downlevel/dart_check.dart <outdir>
//
// Run with `dart <file>` (not `dart run`) so no package resolution is needed:
// js_downlevel.dart only imports dart:convert / dart:typed_data, and we reach it
// through a relative import. That makes this check runnable on a bare Dart SDK.
import 'dart:convert';
import 'dart:io';

import '../../lib/webview/video/js_downlevel.dart';

String _prop(Map<String, dynamic> m, String key, String fallback) =>
    m.containsKey(key) ? '${m[key]}' : fallback;

Future<int> main(List<String> args) async {
  final Directory here = File.fromUri(Platform.script).parent;
  final String outDir = args.isNotEmpty
      ? args[0]
      : '${Directory.current.path}${Platform.pathSeparator}es_downlevel_out';

  final Directory out = Directory(outDir);
  out.createSync(recursive: true);

  final Map<String, dynamic> cases =
      jsonDecode(File('${here.path}${Platform.pathSeparator}cases.json')
              .readAsStringSync()) as Map<String, dynamic>;

  final List<Map<String, dynamic>> report = <Map<String, dynamic>>[];

  // ---- corpus -------------------------------------------------------------
  for (final dynamic raw in cases['cases'] as List<dynamic>) {
    final Map<String, dynamic> c = raw as Map<String, dynamic>;
    final String name = c['name'] as String;
    final String code = c['code'] as String;
    final JsDownlevelResult res;
    try {
      res = JsDownlevel.transform(code);
    } catch (e) {
      report.add(<String, dynamic>{
        'kind': 'case',
        'name': name,
        'error': 'transform threw: $e',
      });
      continue;
    }
    final String produced = res.code ?? code;
    File('$outDir${Platform.pathSeparator}case_$name.js')
        .writeAsStringSync(produced);
    report.add(<String, dynamic>{
      'kind': 'case',
      'name': name,
      'expectChange': c['expectChange'] == true,
      'changed': res.stats.changed,
      'optionalChaining': res.stats.optionalChaining,
      'nullish': res.stats.nullish,
      'logicalAssign': res.stats.logicalAssign,
      'skipped': res.stats.skipped,
      'identical': produced == code,
      'outPath': '$outDir${Platform.pathSeparator}case_$name.js',
    });
  }

  // ---- fixtures -----------------------------------------------------------
  final Directory samples =
      Directory('${here.path}${Platform.pathSeparator}samples');
  if (samples.existsSync()) {
    for (final FileSystemEntity e in samples.listSync()) {
      if (e is! File || !e.path.endsWith('.js')) continue;
      final String base = e.uri.pathSegments.last;
      final List<int> bytes = e.readAsBytesSync();
      final JsDownlevelResult res;
      try {
        res = JsDownlevel.transform(utf8.decode(bytes));
      } catch (err) {
        report.add(<String, dynamic>{
          'kind': 'sample',
          'name': base,
          'error': 'transform threw: $err',
        });
        continue;
      }
      final List<int> produced =
          res.code == null ? bytes : utf8.encode(res.code!);
      final String outPath = '$outDir${Platform.pathSeparator}sample_$base';
      File(outPath).writeAsBytesSync(produced);
      report.add(<String, dynamic>{
        'kind': 'sample',
        'name': base,
        'expectChange': !base.startsWith('unsafe-'),
        'changed': res.stats.changed,
        'optionalChaining': res.stats.optionalChaining,
        'nullish': res.stats.nullish,
        'logicalAssign': res.stats.logicalAssign,
        'skipped': res.stats.skipped,
        'identical': res.code == null,
        'sizeIn': bytes.length,
        'sizeOut': produced.length,
        'srcPath': e.path,
        'outPath': outPath,
      });
    }
  }

  File('$outDir${Platform.pathSeparator}report.json')
      .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));

  stdout.writeln('dart_check: ${report.length} item(s) -> $outDir');
  for (final Map<String, dynamic> r in report) {
    if (r.containsKey('error')) {
      stdout.writeln('  ${_prop(r, 'kind', '?')} ${_prop(r, 'name', '?')} '
          'ERROR ${r['error']}');
      continue;
    }
    stdout.writeln('  ${_prop(r, 'kind', '?').padRight(6)} '
        '${_prop(r, 'name', '?').padRight(28)} '
        'changed=${r['changed']} ?.=${r['optionalChaining']} '
        '??=${r['nullish']} assign=${r['logicalAssign']} '
        'skipped=${(r['skipped'] as List<dynamic>).length}');
  }
  return 0;
}
