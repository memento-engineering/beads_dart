import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

/// One `effects_only_in_leaves` finding or marker: the fixture [file] by
/// name and the 1-based [line].
typedef EffectFinding = ({String file, int line});

const _rule = 'effects_only_in_leaves';

/// The lines of the fixtures in [fixtures] marked `// LINT: <rule>`: each
/// marker names the next line that is not a comment.
Set<EffectFinding> markedEffects(Directory fixtures) {
  final marker = RegExp(
    r'^\s*// LINT: '
    '$_rule'
    r'$',
  );
  final marked = <EffectFinding>{};
  for (final file in _dartFiles(fixtures)) {
    var pending = false;
    for (final (index, line) in file.readAsLinesSync().indexed) {
      if (marker.hasMatch(line)) {
        pending = true;
      } else if (pending && !line.trimLeft().startsWith('//')) {
        marked.add((file: _name(file), line: index + 1));
        pending = false;
      }
    }
  }
  return marked;
}

/// The `effects_only_in_leaves` findings `dart analyze`, run from
/// [workspace], reports on the fixtures in [fixtures], each with the effect
/// it names.
///
/// The rule does not report in a package's `test/` directory, so the
/// fixtures are copied into a directory of this run's own under [package]'s
/// `build/`, with analysis options that include the workspace's, and
/// analyzed there. The run removes only that directory; the workspace's
/// analysis excludes every package's `build/`, so a copy a killed run leaves
/// behind fails nothing, and git ignores it.
Future<Map<EffectFinding, String>> analyzeEffects({
  required Directory fixtures,
  required Directory package,
  required Directory workspace,
}) async {
  final probe = Directory(
    '${package.path}/build/effect_probe.$pid.'
    '${Random().nextInt(1 << 32).toRadixString(16)}',
  )..createSync(recursive: true);
  try {
    File('${probe.path}/analysis_options.yaml').writeAsStringSync(
      'include: ${workspace.absolute.path}/analysis_options.yaml\n',
    );
    for (final file in _dartFiles(fixtures)) {
      file.copySync('${probe.path}/${_name(file)}');
    }
    final analysis = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      '--format=json',
      probe.absolute.path,
    ], workingDirectory: workspace.path);
    final output = analysis.stdout as String;
    final start = output.indexOf('{');
    if (start < 0) {
      throw StateError(
        'dart analyze produced no report: ${analysis.stderr}$output',
      );
    }
    final report = jsonDecode(output.substring(start)) as Map<String, Object?>;
    return {
      for (final diagnostic in report['diagnostics']! as List<Object?>)
        if (diagnostic case {
          'code': _rule,
          'problemMessage': final String message,
          'location': {
            'file': final String path,
            'range': {'start': {'line': final int line}},
          },
        })
          (file: path.split(Platform.pathSeparator).last, line: line):
              RegExp("'([^']+)'").firstMatch(message)?[1] ?? '',
    };
  } finally {
    probe.deleteSync(recursive: true);
  }
}

/// The root of the pub workspace [package] belongs to.
Directory workspaceOf(Directory package) {
  final declaresWorkspace = RegExp(r'^workspace:', multiLine: true);
  var dir = package.absolute;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        declaresWorkspace.hasMatch(pubspec.readAsStringSync())) {
      return dir;
    }
    if (dir.parent.path == dir.path) {
      throw StateError('${package.path} is in no pub workspace.');
    }
    dir = dir.parent;
  }
}

Iterable<File> _dartFiles(Directory directory) => directory
    .listSync()
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);
