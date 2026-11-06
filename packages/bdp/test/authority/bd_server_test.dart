// The server program's work, run in process over a real bd store: it binds
// the port it is given, serves the Scope root and its discovery, and says
// what it runs over. Skipped, naming why, where no bd runs or the store's
// version stamp does not name it.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bdp/bd.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../support/real_bd.dart';

void main() {
  late StampedStore? store;
  late String? absence;

  setUpAll(() async {
    (store, absence) = await StampedStore.create();
  });

  tearDownAll(() async => store?.delete());

  test('the program compiles with dart compile exe, prints its usage for '
      '--help, and exits 64 with it on an unknown flag', () async {
    final out = await Directory.systemTemp.createTemp('serve-bd-');
    addTearDown(() => out.delete(recursive: true));
    final package = File.fromUri(
      Isolate.resolvePackageUriSync(Uri.parse('package:bdp/bd.dart'))!,
    ).parent.parent;
    final binary = '${out.path}/serve_bd';
    // From the workspace root, as the release command runs it: from the
    // package, `dart compile` refuses a package whose dependencies carry
    // build hooks.
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '${package.path}/bin/serve_bd.dart',
      '-o',
      binary,
    ], workingDirectory: package.parent.parent.path);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
    final help = await Process.run(binary, ['--help']);
    expect(help.exitCode, 0);
    expect(
      (help.stdout as String).split('\n').first,
      startsWith('Usage: serve_bd --store=<directory>'),
    );
    final wrong = await Process.run(binary, ['--nope']);
    expect(wrong.exitCode, 64);
    expect(wrong.stderr as String, contains('Usage: serve_bd'));
  });

  test('serves the store at the port it binds, and says the bd version, the '
      'polling interval and the service description, in order', () async {
    if (await stampedCli(store, absence) == null) return;
    final said = <String>[];
    final server = await serveBdStore(
      store: store!.directory.path,
      interval: const Duration(milliseconds: 250),
      actor: 'bdp-test',
      say: said.add,
    );
    addTearDown(server.close);
    final root = Uri.parse(server.url);
    expect(root.host, '127.0.0.1');
    expect(root.port, isNot(0));
    expect(said, [
      'bd: ${store!.version}',
      'polling every 250 ms',
      'service description: ${server.url}bdp.json',
    ]);
    expect(server.bdVersion, store!.version);
    expect(server.interval, const Duration(milliseconds: 250));
    final landing = await http.get(root);
    expect(landing.statusCode, 204);
    expect(landing.headers['link'], contains('rel="service-desc"'));
    final discovery = await http.get(root.resolve('bdp.json'));
    expect(discovery.statusCode, 200);
    final limits =
        (jsonDecode(discovery.body) as Map<String, Object?>)['limits']!
            as Map<String, Object?>;
    expect(limits['transaction'], {'operations': 1});
  });
}
