import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('a program importing gc_api compiles for the web', () async {
    final out = await Directory.systemTemp.createTemp('gc-api-web-');
    addTearDown(() => out.delete(recursive: true));
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      'test/web_entry.dart',
      '-o',
      '${out.path}/web_entry.js',
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
  });
}
