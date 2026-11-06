import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// Pins the client's closed vocabularies to the normative schema bundle, so
/// a bundle refresh that moves an enum fails here rather than on the wire.
void main() {
  final defs =
      fixture('schemas/bdp-v0.schema.json')[r'$defs']! as Map<String, Object?>;

  Set<String> enumOf(String name) {
    final definition = defs[name]! as Map<String, Object?>;
    if (definition['anyOf'] case final List<Object?> parts) {
      return {
        for (final part in parts)
          ...enumOf(
            ((part! as Map<String, Object?>)[r'$ref']! as String)
                .split('/')
                .last,
          ),
      };
    }
    return {...(definition['enum']! as List<Object?>).cast<String>()};
  }

  test('problem codes', () {
    expect(ProblemCodes.read, enumOf('readProblemCode'));
    expect(ProblemCodes.readUpdate, enumOf('readUpdateProblemCode'));
    expect(
      ProblemCodes.transactionalOnly,
      enumOf('transactionalOnlyProblemCode'),
    );
    expect(ProblemCodes.direct, enumOf('directProblemCode'));
    expect(ProblemCodes.receipt, enumOf('receiptProblemCode'));
  });

  test('enumerations', () {
    expect({
      for (final profile in Profile.values) profile.wire,
    }, enumOf('protocolProfile'));
    expect({
      for (final retry in RetryDisposition.values) retry.wire,
    }, enumOf('retryDisposition'));
    expect({
      for (final type in EventType.values) type.name,
    }, enumOf('eventType'));
    expect({
      for (final status in ReceiptStatus.values) status.name,
    }, enumOf('receiptStatus'));
    expect({
      for (final detail in ReceiptDetail.values) detail.name,
    }, enumOf('receiptDetail'));
    expect({
      for (final outcome in ReceiptOutcome.values) outcome.name,
    }, enumOf('receiptEntryOutcome'));
    expect({
      for (final outcome in MutationOutcome.values) outcome.name,
    }, enumOf('mutationOutcome'));
    expect({
      for (final kind in ResourceKind.values) kind.name,
    }, enumOf('resourceKind'));
  });

  test('singleton targets are the Operation Directory names', () {
    final directory =
        (defs['transactionalOperationDirectory']!
                as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    for (final operation in [
      CreateBead.operation,
      UpdateBeadProperties.operation,
      DeleteBead.operation,
      CreateLink.operation,
      UpdateLinkProperties.operation,
      DeleteLink.operation,
      'batch',
    ]) {
      expect(directory, contains(operation));
    }
  });
}
