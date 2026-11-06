// What the package's structure promises, read from its source text: a
// client above the Scope reaches bd only through the Scope, never by running
// it or parsing what it prints; bd runs only asynchronously and only from
// the bd authority; the server program reaches nothing but the bd library;
// and nothing turns off the real-bd tests' version stamp check.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// This package's root, wherever `dart test` was started from.
final Directory _package = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:bdp/bdp.dart'))!,
).parent.parent;

String _relative(File file) =>
    file.path.substring(_package.path.length + 1).replaceAll(r'\', '/');

List<File> _dartFiles(String directory) => [
  for (final entity in Directory(
    '${_package.path}/$directory',
  ).listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity,
];

final _directive = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');

/// The URIs [file] imports or exports.
List<String> _directives(File file) => [
  for (final line in file.readAsLinesSync())
    if (_directive.firstMatch(line) case final match?) match.group(1)!,
];

/// The package's libraries reachable from [roots] by import and export,
/// by path relative to the package.
Set<String> _reachable(List<String> roots) {
  final seen = <String>{};
  final pending = [...roots];
  while (pending.isNotEmpty) {
    final path = pending.removeLast();
    if (!seen.add(path)) continue;
    final file = File('${_package.path}/$path');
    for (final uri in _directives(file)) {
      final String? target;
      if (uri.startsWith('package:bdp/')) {
        target = 'lib/${uri.substring('package:bdp/'.length)}';
      } else if (uri.contains(':')) {
        target = null;
      } else {
        target = _relative(File(file.parent.uri.resolve(uri).toFilePath()));
      }
      if (target != null) pending.add(target);
    }
  }
  return seen;
}

void main() {
  test('no library a client imports from bdp.dart or testing.dart is the bd '
      'library or lies under the bd authority', () {
    final reachable = _reachable(['lib/bdp.dart', 'lib/testing.dart']);
    expect(reachable, contains('lib/src/authority/authority.dart'));
    expect(
      reachable.where(
        (path) =>
            path == 'lib/bd.dart' || path.startsWith('lib/src/authority/bd/'),
      ),
      isEmpty,
    );
  });

  test('no file under lib/ but the bd authority names Process.', () {
    final offenders = [
      for (final file in _dartFiles('lib'))
        if (!_relative(file).startsWith('lib/src/authority/bd/') &&
            file.readAsStringSync().contains('Process.'))
          _relative(file),
    ];
    expect(offenders, isEmpty);
    expect(
      File(
        '${_package.path}/lib/src/authority/bd/bd_cli.dart',
      ).readAsStringSync(),
      contains('Process.start('),
    );
  });

  test('no file under lib/ or bin/ runs a process synchronously', () {
    final offenders = [
      for (final file in [..._dartFiles('lib'), ..._dartFiles('bin')])
        if (RegExp(
          r'\b(runSync|startSync)\b',
        ).hasMatch(file.readAsStringSync()))
          _relative(file),
    ];
    expect(offenders, isEmpty);
  });

  test('the server program imports only dart: libraries and the bd '
      'library', () {
    final imports = _directives(File('${_package.path}/bin/serve_bd.dart'));
    expect(imports, contains('package:bdp/bd.dart'));
    expect(
      imports.where(
        (uri) => !uri.startsWith('dart:') && uri != 'package:bdp/bd.dart',
      ),
      isEmpty,
    );
  });

  test('the real-bd support reads no environment variable and declares no '
      'flag, so nothing turns its stamp check off', () {
    final text = File(
      '${_package.path}/test/support/real_bd.dart',
    ).readAsStringSync();
    for (final forbidden in [
      'Platform.environment',
      'fromEnvironment',
      'ArgParser',
      'addFlag',
      'addOption',
      'executableArguments',
    ]) {
      expect(text, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('client.dart exports what bdp.dart does but the authority, and '
      'reaches no authority file, dart:io, dart:ffi, SQLite or shelf', () {
    final client = _directives(File('${_package.path}/lib/client.dart'));
    final full = _directives(File('${_package.path}/lib/bdp.dart'));
    expect(
      client.toSet(),
      full.where((uri) => !uri.startsWith('src/authority/')).toSet(),
    );
    final reachable = _reachable(['lib/client.dart']);
    expect(
      reachable.where((path) => path.startsWith('lib/src/authority/')),
      isEmpty,
    );
    final platform = [
      for (final path in reachable)
        for (final uri in _directives(File('${_package.path}/$path')))
          if (uri == 'dart:io' ||
              uri == 'dart:ffi' ||
              uri.startsWith('package:sqlite3/') ||
              uri.startsWith('package:shelf/'))
            '$path: $uri',
    ];
    expect(platform, isEmpty);
  });

  test('a program importing client.dart compiles for the web', () async {
    final out = await Directory.systemTemp.createTemp('bdp-web-');
    addTearDown(() => out.delete(recursive: true));
    final entry = File('${_package.path}/test/support/web_entry.dart');
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      entry.path,
      '-o',
      '${out.path}/web_entry.js',
    ], workingDirectory: _package.path);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
  });
}
