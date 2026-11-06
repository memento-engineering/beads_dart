import 'dart:convert';
import 'dart:io';

import 'package:bdp/bdp.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

const scope = 'https://beads.example/acme/';
const taskType = 'https://work.example/types/task';
const decisionType = 'https://work.example/types/decision';
const citesType = 'https://work.example/types/cites';
const blocksType = 'https://work.example/types/blocks';

/// A clock tests can move.
final class TestClock {
  DateTime now = DateTime.utc(2026, 9, 7, 18, 4, 12);
  DateTime call() => now;
}

/// Installs the work Types the fixtures use. `task` requires a string
/// `title`; `cites` runs from a decision to a task.
void installWorkTypes(ScopeAuthority authority) {
  authority
    ..installType(
      {
        'id': taskType,
        'name': 'Task',
        'describes': 'bead',
        'conformsTo': <String>[],
        'propertiesSchema': 'https://work.example/schemas/task',
      },
      schema: {
        'type': 'object',
        'required': ['title'],
        'properties': {
          'title': {'type': 'string', 'minLength': 1},
          'status': {
            'enum': ['open', 'cited', 'closed'],
          },
        },
      },
    )
    ..installType({
      'id': decisionType,
      'name': 'Decision',
      'describes': 'bead',
      'conformsTo': <String>[],
    })
    ..installType({
      'id': citesType,
      'name': 'Cites',
      'describes': 'link',
      'conformsTo': <String>[],
      'source': {
        'conformsTo': [decisionType],
      },
      'target': {'conformsTo': <String>[]},
    })
    ..installType({
      'id': blocksType,
      'name': 'Blocks',
      'describes': 'link',
      'conformsTo': <String>[],
      'source': {
        'conformsTo': [taskType],
        'external': 'none',
      },
      'target': {
        'conformsTo': [taskType],
        'external': 'bead',
      },
    });
}

/// A fresh in-memory authority with the work Types installed.
ScopeAuthority memoryAuthority(TestClock clock) {
  final authority = ScopeAuthority.memory(scope: scope, clock: clock.call);
  installWorkTypes(authority);
  return authority;
}

String get _fixtures => '${Directory.current.path}/test/fixtures/bdp';

/// A vendored Transactional BDP fixture document.
Json fixture(String name) =>
    jsonDecode(File('$_fixtures/transactional/$name.json').readAsStringSync())
        as Json;

/// The exchange [id] of fixture [name].
Json exchange(String name, String id) => (fixture(name)['exchanges']! as List)
    .cast<Json>()
    .singleWhere((e) => e['id'] == id);

final Json _bundle =
    jsonDecode(File('$_fixtures/schemas/bdp-v0.schema.json').readAsStringSync())
        as Json;
final Map<String, JsonSchema> _compiled = {};

/// Asserts [value] validates against the bundle's `$defs/[definition]`.
void expectSchema(Object? value, String definition) {
  final schema = _compiled.putIfAbsent(
    definition,
    () => JsonSchema.create({..._bundle, r'$ref': '#/\$defs/$definition'}),
  );
  final result = schema.validate(value);
  expect(
    result.errors,
    isEmpty,
    reason: '$definition: ${const JsonEncoder.withIndent(' ').convert(value)}',
  );
}

/// The change groups of a changefeed page.
List<Json> groupsOf(AuthorityRead page) =>
    (page.body['groups']! as List).cast<Json>();

/// The receipt's result entries.
List<Json> results(AuthorityReceipt receipt) => receipt.results;

/// Creates a task Bead and returns its record.
Json createTask(
  ScopeAuthority authority,
  String id, {
  String title = 'Specify BDP mutation',
  String status = 'open',
}) {
  final receipt = authority.createBeadJson({
    'id': id,
    'type': taskType,
    'properties': {'title': title, 'status': status},
  }, idempotencyKey: 'setup-${id.replaceAll('/', '-')}');
  expect(receipt.status, 'completed', reason: '${receipt.json}');
  return receipt.results.single['resource']! as Json;
}

/// The authority's mutation targets fed raw request JSON, exactly as its HTTP
/// handler feeds them, for tests that pin the wire documents themselves.
extension AuthorityJsonMutations on ScopeAuthority {
  AuthorityReceipt createBeadJson(
    Json record, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'create-bead',
    record,
    idempotencyKey: idempotencyKey,
    principal: principal,
  );

  AuthorityReceipt updateBeadPropertiesJson(
    Json record, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'update-bead-properties',
    record,
    idempotencyKey: idempotencyKey,
    principal: principal,
  );

  AuthorityReceipt deleteBeadJson(
    Json record, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'delete-bead',
    record,
    idempotencyKey: idempotencyKey,
    principal: principal,
  );

  AuthorityReceipt createLinkJson(
    Json record, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'create-link',
    record,
    idempotencyKey: idempotencyKey,
    principal: principal,
  );

  AuthorityReceipt updateLinkPropertiesJson(
    Json record, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'update-link-properties',
    record,
    idempotencyKey: idempotencyKey,
    principal: principal,
  );

  AuthorityReceipt deleteLinkJson(
    Json record, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'delete-link',
    record,
    idempotencyKey: idempotencyKey,
    principal: principal,
  );

  AuthorityReceipt batchJson(
    List<Json> operations, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
  }) => mutate(
    'batch',
    {'operations': operations},
    idempotencyKey: idempotencyKey,
    principal: principal,
  );
}
