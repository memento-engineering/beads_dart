import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// Decode-then-encode for every schema definition the client models.
final Map<String, Object? Function(Object? json)> codecs = {
  'transactionalDiscovery': (json) => ScopeDiscovery.fromJson(json).toJson(),
  'readUpdateDiscovery': (json) => ScopeDiscovery.fromJson(json).toJson(),
  'transactionalOperationDirectory': (json) =>
      OperationDirectory.fromJson(json).toJson(),
  'readUpdateOperationDirectory': (json) =>
      OperationDirectory.fromJson(json).toJson(),
  'batchRequest': (json) => BatchRequest.fromJson(json).toJson(),
  for (final (schema, operation) in [
    ('createBeadRequest', CreateBead.operation),
    ('updateBeadPropertiesRequest', UpdateBeadProperties.operation),
    ('deleteBeadRequest', DeleteBead.operation),
    ('createLinkRequest', CreateLink.operation),
    ('updateLinkPropertiesRequest', UpdateLinkProperties.operation),
    ('deleteLinkRequest', DeleteLink.operation),
  ])
    schema: (json) =>
        MutationOperation.fromRequestJson(operation, json).toRequestJson(),
  'mutationResult': (json) => MutationResult.fromJson(json).toJson(),
  'mutationReceipt': (json) => MutationReceipt.fromJson(json).toJson(),
  'mutationReceiptPage': (json) => MutationReceiptPage.fromJson(json).toJson(),
  'changefeedPage': (json) => ChangefeedPage.fromJson(json).toJson(),
  'changeGroup': (json) => ChangeGroup.fromJson(json).toJson(),
  'eventPage': (json) => EventPage.fromJson(json).toJson(),
  'snapshotManifest': (json) => SnapshotManifest.fromJson(json).toJson(),
  'transactionalProblem': (json) => ProblemDetails.fromJson(json).toJson(),
  'readUpdateProblem': (json) => ProblemDetails.fromJson(json).toJson(),
};

/// Schema definitions the fixtures use that are deliberately outside this
/// client: alias targets, set mutations and the `sequence` carrier.
const Set<String> outOfSubset = {
  'putAliasRequest',
  'deleteAliasRequest',
  'updateWhereRequest',
  'deleteWhereRequest',
  'sequenceRequest',
  'transactionalSequenceResponse',
};

const List<String> fixtureFiles = [
  'transactional/discovery.json',
  'transactional/batch.json',
  'transactional/changefeed.json',
  'transactional/events.json',
  'transactional/receipts.json',
  'transactional/receipt-pagination.json',
  'transactional/snapshots.json',
  'transactional/sequence.json',
  'transactional/http-contracts.json',
  'transactional/direct-problems.json',
  'read-update/discovery.json',
  'read-update/singletons.json',
];

String? schemaName(Object? ref) =>
    ref is String ? ref.substring(ref.lastIndexOf('/') + 1) : null;

void expectRoundTrip(String schema, Object? body) {
  final codec = codecs[schema];
  expect(codec, isNotNull, reason: 'no codec for $schema');
  expect(codec!(body), equals(body), reason: '$schema did not round-trip');
}

/// Round-trips one fixture message (request or response) and reports what
/// it checked.
String checkMessage(
  Map<String, Object?> message, {
  required bool response,
  bool refused = false,
}) {
  final body = bodyOf(message);
  if (body == null) return 'bodyless';
  final schema = schemaName(message['schema']);
  if (refused) {
    // The authority refused this request as malformed; the client's decoder
    // either refuses the same shape or reproduces it exactly.
    try {
      if (schema != null) expectRoundTrip(schema, body);
      return 'refused request';
    } on FormatException {
      return 'refused request, refused by the decoder too';
    }
  }
  if (schema == 'batchRequest' && _hasSetOperation(body)) {
    expect(
      () => BatchRequest.fromJson(body),
      throwsA(isA<UnsupportedOperation>()),
    );
    return 'batch with a set operation refused';
  }
  if (schema == 'sequenceRequest') {
    // The carrier is out of subset; its members are ordinary operation
    // records plus a member key.
    for (final member
        in (body as Map<String, Object?>)['operations']! as List<Object?>) {
      final record = {...member! as Map<String, Object?>}
        ..remove('idempotencyKey');
      expect(
        MutationOperation.fromBatchJson(record).toBatchJson(),
        equals(record),
      );
    }
    return 'sequence members';
  }
  if (schema == 'transactionalSequenceResponse') {
    for (final entry
        in (body as Map<String, Object?>)['results']! as List<Object?>) {
      final json = entry! as Map<String, Object?>;
      final copy = json.containsKey('code')
          ? ProblemDetails.fromJson(json).toJson()
          : ReceiptResult.fromJson(json).toJson();
      expect(copy, equals(json));
    }
    return 'sequence entries';
  }
  if (schema != null) {
    if (outOfSubset.contains(schema)) return 'out of subset: $schema';
    expectRoundTrip(schema, body);
    return schema;
  }
  if (!response) return 'deliberately malformed request';
  final status = message['status'];
  if (status is int && status >= 400) {
    expectRoundTrip('transactionalProblem', body);
    return 'problem';
  }
  fail('unclassified body: $message');
}

bool _hasSetOperation(Object? body) =>
    ((body! as Map<String, Object?>)['operations']! as List<Object?>).any(
      (operation) =>
          switch ((operation! as Map<String, Object?>)['operation']) {
            'updateWhere' || 'deleteWhere' => true,
            _ => false,
          },
    );

void main() {
  for (final path in fixtureFiles) {
    group(path, () {
      final file = fixture(path);
      final exchanges = exchangesOf(file);

      test('has exchanges with bodies', () {
        expect(
          exchanges.where(
            (entry) =>
                bodyOf(requestOf(entry)) != null ||
                bodyOf(responseOf(entry)) != null,
          ),
          isNotEmpty,
        );
      });

      for (final entry in exchanges) {
        test('${entry['id']} round-trips', () {
          checkMessage(
            requestOf(entry),
            response: false,
            refused: responseOf(entry)['status'] == 400,
          );
          checkMessage(responseOf(entry), response: true);
        });
      }
    });
  }

  group('changefeed committed groups', () {
    final file = fixture('transactional/changefeed.json');
    for (final example in file['groupExamples']! as List<Object?>) {
      final json = example! as Map<String, Object?>;
      test('${json['id']} round-trips', () {
        expect(schemaName(json['schema']), 'changeGroup');
        expectRoundTrip('changeGroup', json['body']);
      });
    }
    for (final example in file['livePublicationExamples']! as List<Object?>) {
      final json = example! as Map<String, Object?>;
      final sse = json['sse'] as Map<String, Object?>?;
      if (sse == null) continue;
      test('${json['id']} SSE data round-trips', () {
        final group = ChangeGroup.fromJson(sse['data']);
        expect(group.toJson(), equals(sse['data']));
        expect(group.checkpoint.value, sse['id']);
      });
    }
  });

  group('reference domain', () {
    final domain = fixture('reference-domain/reference-domain.json');
    test('Type Descriptors round-trip', () {
      for (final json in domain['typeDescriptors']! as List<Object?>) {
        expect(TypeDescriptor.fromJson(json).toJson(), equals(json));
      }
    });
    test('Type summaries round-trip', () {
      for (final json in [
        ...domain['beadTypes']! as List<Object?>,
        ...domain['linkTypes']! as List<Object?>,
      ]) {
        expect(TypeSummary.fromJson(json).toJson(), equals(json));
      }
    });
    test('a pinned revision is echoed byte for byte', () {
      final link =
          (domain['externalEndpointLinks']! as List<Object?>).first!
              as Map<String, Object?>;
      final target = Reference.fromJson(link['target']);
      expect(target, isA<PinnedReference>());
      final written = (link['target']! as Map<String, Object?>)['revision'];
      final pin = (target as PinnedReference).revision.value;
      expect(pin.codeUnits, (written! as String).codeUnits);
      // The fixture spells Å decomposed; nothing normalizes it.
      expect(pin.runes, contains(0x030A));
      expect(target.toJson(), equals(link['target']));
    });
  });

  group('tokens', () {
    test('a number where a token belongs is refused, not reinterpreted', () {
      expect(() => Revision.fromJson(7), throwsFormatException);
      expect(() => Checkpoint.fromJson(42), throwsFormatException);
      expect(
        () => BeadRecord.fromJson({
          'id': 'https://beads.example/acme/beads/x',
          'type': 'https://work.example/types/task',
          'revision': 1,
          'properties': <String, Object?>{},
        }),
        throwsFormatException,
      );
    });

    test('wire tokens hold the character profile', () {
      expect(() => Checkpoint('has space'), throwsArgumentError);
      expect(() => Checkpoint.fromJson('100%'), throwsFormatException);
      expect(Checkpoint.genesis.value, 'genesis');
    });

    test('tokens of different kinds are never equal', () {
      expect(Revision('pos-1'), isNot(ScopePosition('pos-1')));
      expect(Revision('r1'), Revision('r1'));
      expect(Revision('r1').hashCode, Revision('r1').hashCode);
    });

    test('generated idempotency keys are valid and distinct', () {
      final keys = {for (var i = 0; i < 64; i++) IdempotencyKey.generate()};
      expect(keys, hasLength(64));
    });
  });
}
