import 'dart:io';

import 'package:bdp/bdp.dart';

import 'scope.dart';

/// Writes Beads into the store at `args[0]` until killed, acknowledging each
/// committed group's position on stdout.
Future<void> main(List<String> args) async {
  final authority = ScopeAuthority.file(args.single, scope: scope);
  stdout.writeln('epoch ${authority.epoch}');
  for (var i = 0; ; i++) {
    final receipt = authority.createBeadJson({
      'type': taskType,
      'properties': {'title': 'crash $i'},
    }, idempotencyKey: 'crash-$i');
    stdout.writeln('committed ${receipt.json['effectPosition']}');
    await stdout.flush();
  }
}
