// Pins that this package's generated test entry, test/all_test.dart, and the
// paths: block of its dart_test.yaml are what tool/test_entry.dart renders:
// every test file is called, none absent is, and no file the tool lists as
// run apart is imported.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/test_entry.dart';

void main() {
  test('the generated entry and the paths block are current', () {
    final findings = staleness(Directory.current, kRunApart['bdp'] ?? const {});
    expect(findings, isEmpty, reason: findings.join('\n'));
  });
}
