import 'dart:io';

import 'package:bdp/bdp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

void main() {
  AuthorityTypeRegistry registry() => AuthorityTypeRegistry()
    ..install(
      AuthorityTypeDescriptor.fromJson({
        'id': 'https://t.example/item',
        'name': 'Item',
        'describes': 'bead',
        'propertiesSchema': 'https://t.example/item.schema',
      }),
      schema: {
        r'$defs': {
          'slug': {'type': 'string', 'pattern': r'^[a-z-]+$', 'maxLength': 8},
        },
        'properties': {
          'slug': {r'$ref': r'#/$defs/slug'},
          'size': {'type': 'integer', 'minimum': 1, 'exclusiveMaximum': 10},
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
            'uniqueItems': true,
            'maxItems': 2,
          },
          'kind': {
            'oneOf': [
              {'const': 'a'},
              {'const': 'b'},
            ],
          },
          'meta': {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'note': {
                'anyOf': [
                  {'type': 'string'},
                  {'type': 'null'},
                ],
              },
            },
          },
          'flag': {
            'not': {'const': false},
          },
        },
      },
    )
    ..install(
      AuthorityTypeDescriptor.fromJson({
        'id': 'https://t.example/special',
        'name': 'Special',
        'describes': 'bead',
        'conformsTo': ['https://t.example/item'],
      }),
    );

  test('a valid value has no diagnostics through conformance', () {
    expect(
      registry().validate('https://t.example/special', {
        'slug': 'ok-slug',
        'size': 3,
        'tags': ['x', 'y'],
        'kind': 'a',
        'meta': {'note': null},
        'flag': true,
        'undeclared': {'anything': 1},
      }),
      isEmpty,
    );
  });

  test('each keyword reports its own location', () {
    final diagnostics = registry().validate('https://t.example/special', {
      'slug': 'Not A Slug',
      'size': 10,
      'tags': ['x', 'x', 'y'],
      'kind': 'c',
      'meta': {'note': 1, 'extra': true},
      'flag': false,
    });
    final locations = diagnostics.map((d) => d['schemaLocation']).toSet();
    expect(
      diagnostics.every((d) => d['type'] == 'https://t.example/item'),
      isTrue,
    );
    expect(
      locations,
      containsAll([
        r'https://t.example/item.schema#/$defs/slug/pattern',
        r'https://t.example/item.schema#/$defs/slug/maxLength',
        'https://t.example/item.schema#/properties/size/exclusiveMaximum',
        'https://t.example/item.schema#/properties/tags/uniqueItems',
        'https://t.example/item.schema#/properties/tags/maxItems',
        'https://t.example/item.schema#/properties/kind/oneOf',
        'https://t.example/item.schema#/properties/meta/properties/note/anyOf',
        'https://t.example/item.schema#/properties/meta/additionalProperties',
        'https://t.example/item.schema#/properties/flag/not',
      ]),
    );
    expect(
      diagnostics.firstWhere(
        (d) =>
            (d['schemaLocation']! as String).endsWith('/additionalProperties'),
      )['instanceLocation'],
      '/meta/extra',
    );
  });

  test('installation refuses what it cannot validate or pin', () {
    final r = registry();
    Matcher refused = throwsA(isA<ArgumentError>());
    // A Type ID is an absolute http(s) URL, as operations require it to be.
    expect(
      () => AuthorityTypeDescriptor.fromJson({
        'id': 'urn:t:x',
        'name': 'X',
        'describes': 'bead',
      }),
      refused,
    );
    expect(
      () => r.install(
        AuthorityTypeDescriptor.fromJson({
          'id': 'https://t.example/x',
          'name': 'X',
          'describes': 'bead',
          'propertiesSchema': 'https://t.example/x.schema',
        }),
        schema: {'dependentRequired': <String, Object?>{}},
      ),
      refused,
    );
    expect(
      () => r.install(
        AuthorityTypeDescriptor.fromJson({
          'id': 'https://t.example/y',
          'name': 'Y',
          'describes': 'bead',
          'propertiesSchema': 'https://t.example/y.schema',
        }),
        schema: {'additionalProperties': false},
      ),
      refused,
    );
    expect(
      () => r.install(
        AuthorityTypeDescriptor.fromJson({
          'id': 'https://t.example/z',
          'name': 'Z',
          'describes': 'link',
          'conformsTo': ['https://t.example/item'],
        }),
      ),
      refused,
    );
    expect(
      () => AuthorityTypeDescriptor.fromJson({
        'id': 'x',
        'name': 'X',
        'describes': 'bead',
      }),
      refused,
    );
  });

  group('unsupported schema constructs are refused at installation', () {
    final refused = throwsA(isA<ArgumentError>());
    AuthorityTypeDescriptor item(String name) =>
        AuthorityTypeDescriptor.fromJson({
          'id': 'https://t.example/$name',
          'name': name,
          'describes': 'bead',
          'propertiesSchema': 'https://t.example/$name.schema',
        });

    for (final (why, schema) in <(String, Json)>[
      (
        'another dialect',
        {r'$schema': 'http://json-schema.org/draft-07/schema#'},
      ),
      (
        'a nested dialect',
        {
          'properties': {
            'a': {r'$schema': 'https://json-schema.org/draft/2020-12/schema'},
          },
        },
      ),
      (
        'an anchor fragment',
        {
          r'$defs': {
            'a': {'type': 'string'},
          },
          'properties': {
            'a': {r'$ref': '#foo'},
          },
        },
      ),
      (
        'an embedded resource',
        {
          'properties': {
            'a': {r'$id': 'https://t.example/other'},
          },
        },
      ),
      (
        'a remote reference',
        {
          'properties': {
            'a': {r'$ref': 'https://t.example/other#/x'},
          },
        },
      ),
      (
        'a badly encoded reference',
        {
          'properties': {
            'a': {r'$ref': '#/%C3'},
          },
        },
      ),
      (
        'a reference to nothing',
        {
          'properties': {
            'a': {r'$ref': r'#/$defs/missing'},
          },
        },
      ),
      (
        'a reference to a non-schema location',
        {
          'properties': {
            'a': {r'$ref': '#/properties'},
          },
        },
      ),
      (
        'a reference cycle that never descends',
        {
          r'$defs': {
            'a': {r'$ref': r'#/$defs/b'},
            'b': {
              'allOf': [
                {r'$ref': r'#/$defs/a'},
              ],
            },
          },
        },
      ),
      ('an unknown type name', {'type': 'strng'}),
      ('a non-integer bound', {'minLength': '3'}),
      ('a fractional bound', {'maxItems': 1.5}),
      ('a non-numeric limit', {'minimum': '0'}),
      ('a bad pattern', {'pattern': '('}),
      ('a non-array required', {'required': 'title'}),
      (
        'a repeated required name',
        {
          'required': ['title', 'title'],
        },
      ),
      (
        'a repeated type name',
        {
          'type': ['string', 'string'],
        },
      ),
      ('a non-array examples', {'examples': 'x'}),
      ('a non-array enum', {'enum': 'x'}),
      ('a non-string description', {'description': 1}),
      ('a non-boolean annotation', {'readOnly': 'yes'}),
      ('a root id with a fragment', {r'$id': 'https://t.example/s#part'}),
      ('an empty anyOf', {'anyOf': <Object?>[]}),
      (
        'an array items',
        {
          'items': [
            {'type': 'string'},
          ],
        },
      ),
    ]) {
      test(why, () {
        final r = AuthorityTypeRegistry();
        expect(() => r.install(item('x'), schema: schema), refused);
        expect(r['https://t.example/x'], isNull);
      });
    }

    test('what the validator implements still installs and validates', () {
      final r = AuthorityTypeRegistry()
        ..install(
          item('tree'),
          schema: {
            r'$schema': 'https://json-schema.org/draft/2020-12/schema',
            r'$id': 'https://t.example/tree.schema#',
            'title': 'Tree',
            'examples': [<String, Object?>{}],
            r'$defs': {
              'node': {
                'type': 'object',
                'required': ['name'],
                'properties': {
                  'name': {r'$ref': r'#/$defs/a%20name'},
                  'children': {
                    'type': 'array',
                    'items': {r'$ref': r'#/$defs/node'},
                  },
                },
              },
              'a name': {'type': 'string', 'minLength': 1},
            },
            'properties': {
              'root': {r'$ref': r'#/$defs/node'},
            },
          },
        );
      Json tree(String leaf) => {
        'root': {
          'name': 'r',
          'children': [
            {'name': leaf},
          ],
        },
      };
      expect(r.validate('https://t.example/tree', tree('leaf')), isEmpty);
      expect(
        r
            .validate('https://t.example/tree', tree(''))
            .map((d) => d['instanceLocation']),
        ['/root/children/0/name'],
      );
    });
  });

  group('installed Type contracts are pinned', () {
    late Directory dir;
    late String path;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('bdp-types-');
      path = '${dir.path}/scope.db';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    const noteType = 'https://work.example/types/note';
    Json note({required int maxLength}) => {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'maxLength': maxLength},
      },
    };
    const noteDescriptor = {
      'id': noteType,
      'name': 'Note',
      'describes': 'bead',
      'propertiesSchema': 'https://work.example/schemas/note',
    };
    String outcome(ScopeAuthority authority, String text, String key) {
      final receipt = authority.createBeadJson({
        'type': noteType,
        'properties': {'text': text},
      }, idempotencyKey: key);
      return receipt.status == 'completed'
          ? 'completed'
          : receipt.problem!['code']! as String;
    }

    test('a Type installed on one connection is the contract every '
        'connection validates against', () {
      final a = ScopeAuthority.file(path, scope: scope);
      final b = ScopeAuthority.file(path, scope: scope);
      addTearDown(a.close);
      addTearDown(b.close);
      a.installType(noteDescriptor, schema: note(maxLength: 3));
      expect(outcome(b, 'four', 'b-1'), 'validation-failed');
      expect(outcome(b, 'abc', 'b-2'), 'completed');
      expect(b.typeRegistry[noteType], isNotNull);
      // B pins another contract at the same Type ID as its second revision,
      // the current contract A validates against too.
      expect(
        b.installType(noteDescriptor, schema: note(maxLength: 10)),
        isNotNull,
      );
      expect(outcome(b, 'four', 'b-3'), 'completed');
      expect(outcome(a, 'fives', 'a-1'), 'completed');
      expect(a.typeRegistry.revisionsOf(noteType), hasLength(2));
      // Reinstalling the current contract is a no-op on either connection.
      expect(
        a.installType(noteDescriptor, schema: note(maxLength: 10)),
        isNull,
      );
      expect(
        b.installType(noteDescriptor, schema: note(maxLength: 10)),
        isNull,
      );
      expect(b.typeRegistry.revisionsOf(noteType), hasLength(2));
      expect(
        groupsOf(b.changePage(after: 'genesis')).map((g) => g['position']),
        ['p1', 'p2', 'p3'],
      );
    });

    test('a Type the store refused to pin is not visible', () {
      final authority = ScopeAuthority.file(path, scope: scope);
      addTearDown(authority.close);
      final raw = sqlite3.open(path)
        ..execute(
          'CREATE TRIGGER refuse_pin BEFORE INSERT ON types '
          "BEGIN SELECT RAISE(ABORT, 'refused'); END",
        );
      addTearDown(raw.close);
      expect(
        () => authority.installType(noteDescriptor, schema: note(maxLength: 3)),
        throwsA(isA<SqliteException>()),
      );
      expect(authority.typeRegistry[noteType], isNull);
      expect(outcome(authority, 'abc', 'k'), 'type-not-installed');
    });

    test('installed schemas are immutable copies', () {
      final authority = ScopeAuthority.memory(scope: scope);
      addTearDown(authority.close);
      final schema = note(maxLength: 3);
      authority.installType(noteDescriptor, schema: schema);
      ((schema['properties']! as Json)['text']! as Json)['maxLength'] = 100;
      expect(outcome(authority, 'four', 'k1'), 'validation-failed');
      final pinned = authority.typeRegistry.schemaOf(
        authority.typeRegistry[noteType]!,
      )!;
      expect(
        () =>
            ((pinned['properties']! as Json)['text']! as Json)['maxLength'] = 9,
        throwsUnsupportedError,
      );
      expect(() => pinned['extra'] = true, throwsUnsupportedError);
      expect(
        () => authority.typeRegistry.install(
          AuthorityTypeDescriptor.fromJson({
            'id': 'https://work.example/types/sneaky',
            'name': 'Sneaky',
            'describes': 'bead',
          }),
        ),
        throwsStateError,
      );
    });
  });

  group('a changed Type installs as a new revision beside the pinned one', () {
    late Directory dir;
    late String path;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('bdp-revisions-');
      path = '${dir.path}/scope.db';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    const noteType = 'https://work.example/types/note';
    const parentType = 'https://work.example/types/parent';
    const noteDescriptor = {
      'id': noteType,
      'name': 'Note',
      'describes': 'bead',
      'propertiesSchema': 'https://work.example/schemas/note',
    };
    // The first revision: a short text and a size.
    Json first() => {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'maxLength': 3},
        'size': {'type': 'integer'},
        'state': {
          'enum': ['open', 'done'],
        },
      },
    };
    // A revision that only adds: a longer text, an optional member, a state.
    Json added() => {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'maxLength': 10},
        'size': {'type': 'integer'},
        'state': {
          'enum': ['open', 'done', 'skipped'],
        },
        'tag': {'type': 'string'},
      },
    };
    // A revision that removes `size` and retypes `state`.
    Json narrowed() => {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'state': {'type': 'integer'},
      },
    };
    AuthorityTypeDescriptor descriptor([Json extra = const {}]) =>
        AuthorityTypeDescriptor.fromJson({...noteDescriptor, ...extra});
    String revisionOf(Json schema) =>
        authorityTypeRevisionOf(descriptor(), schema);
    Json create(ScopeAuthority authority, Json properties, String key) {
      final receipt = authority.createBeadJson({
        'type': noteType,
        'properties': properties,
      }, idempotencyKey: key);
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      return receipt.results.single['resource']! as Json;
    }

    String outcome(ScopeAuthority authority, Json properties, String key) {
      final receipt = authority.createBeadJson({
        'type': noteType,
        'properties': properties,
      }, idempotencyKey: key);
      return receipt.status == 'completed'
          ? 'completed'
          : receipt.problem!['code']! as String;
    }

    test('a descriptor whose content differs installs as a second revision, '
        'refusing nothing, and the beads written under the first stay as '
        'written', () {
      final authority = ScopeAuthority.file(path, scope: scope);
      addTearDown(authority.close);
      final pinned = authority.installType(noteDescriptor, schema: first());
      expect(pinned?.type, noteType);
      expect(pinned?.revision, revisionOf(first()));
      final old = create(authority, {'text': 'abc', 'size': 1}, 'old');
      expect(
        outcome(authority, {'text': 'four'}, 'refused'),
        'validation-failed',
      );

      final second = authority.installType(noteDescriptor, schema: added());
      expect(second, isNotNull);
      expect(second!.type, noteType);
      expect(second.revision, revisionOf(added()));
      expect(second.schema, added());
      expect(
        authority.typeRegistry.revisionsOf(noteType).map((r) => r.revision),
        [revisionOf(first()), revisionOf(added())],
      );
      final read = authority.resource(old['id']! as String).body;
      expect(read['revision'], old['revision']);
      expect(read['properties'], {'text': 'abc', 'size': 1});

      // Writes are validated against the second revision.
      expect(
        outcome(authority, {'text': 'four', 'state': 'skipped'}, 'new'),
        'completed',
      );
      expect(
        outcome(authority, {'text': 'eleven-long'}, 'long'),
        'validation-failed',
      );
      final registry = authority.typeRegistry;
      expect(registry.schemaOf(registry[noteType]!), added());
      expect(registry.validate(noteType, {'tag': 'x'}), isEmpty);
      expect(registry.validate(noteType, {'tag': 1}), isNotEmpty);
    });

    test('an identical descriptor installs nothing, revisions survive '
        'reopening and reinitialization in order, and earlier content '
        'reinstalled is a third revision', () {
      final a = ScopeAuthority.file(path, scope: scope);
      addTearDown(a.close);
      a.installType(noteDescriptor, schema: first());
      a.installType(noteDescriptor, schema: added());
      final groups = groupsOf(a.changePage(after: 'genesis')).length;
      expect(a.installType(noteDescriptor, schema: added()), isNull);
      expect(a.typeRegistry.revisionsOf(noteType), hasLength(2));
      expect(groupsOf(a.changePage(after: 'genesis')), hasLength(groups));

      final expected = [revisionOf(first()), revisionOf(added())];
      final b = ScopeAuthority.file(path, scope: scope);
      addTearDown(b.close);
      expect(
        b.typeRegistry.revisionsOf(noteType).map((r) => r.revision),
        expected,
      );
      b.reinitialize();
      expect(
        b.typeRegistry.revisionsOf(noteType).map((r) => r.revision),
        expected,
      );
      a.close();
      final c = ScopeAuthority.file(path, scope: scope);
      addTearDown(c.close);
      expect(
        c.typeRegistry.revisionsOf(noteType).map((r) => r.revision),
        expected,
      );

      final third = c.installType(noteDescriptor, schema: first());
      expect(third?.revision, revisionOf(first()));
      expect(c.typeRegistry.revisionsOf(noteType).map((r) => r.revision), [
        ...expected,
        revisionOf(first()),
      ]);
      expect(outcome(c, {'text': 'four'}, 'third'), 'validation-failed');
      expect(outcome(b, {'text': 'four'}, 'third-b'), 'validation-failed');
    });

    test('a revision that changes what the Type describes, or would make '
        'conformance cyclic, is refused and pins nothing', () {
      final authority = ScopeAuthority.file(path, scope: scope);
      addTearDown(authority.close);
      authority.installType(noteDescriptor, schema: first());
      authority.installType({
        'id': parentType,
        'name': 'Parent',
        'describes': 'bead',
        'conformsTo': [noteType],
      });
      expect(
        () => authority.installType({
          'id': noteType,
          'name': 'Note',
          'describes': 'link',
        }),
        throwsArgumentError,
      );
      expect(
        () => authority.installType({
          ...noteDescriptor,
          'conformsTo': [parentType],
        }, schema: first()),
        throwsArgumentError,
      );
      expect(authority.typeRegistry.revisionsOf(noteType), hasLength(1));
      // A missing parent and an unsupported construct still throw.
      expect(
        () => authority.installType({
          ...noteDescriptor,
          'conformsTo': ['https://work.example/types/missing'],
        }, schema: first()),
        throwsArgumentError,
      );
      expect(
        () => authority.installType(
          noteDescriptor,
          schema: {'dependentRequired': <String, Object?>{}},
        ),
        throwsArgumentError,
      );
      expect(authority.typeRegistry.revisionsOf(noteType), hasLength(1));
      final reopened = ScopeAuthority.file(path, scope: scope);
      addTearDown(reopened.close);
      expect(reopened.typeRegistry.revisionsOf(noteType), hasLength(1));
    });

    test('project reads properties written under an earlier revision through '
        'the current one', () {
      final registry = AuthorityTypeRegistry()
        ..install(descriptor(), schema: first());
      final written = {'text': 'abc', 'size': 2, 'state': 'done'};
      expect(registry.project(noteType, written), isEmpty);
      registry.install(descriptor(), schema: added());
      expect(registry.revisionsOf(noteType), hasLength(2));
      // Only added: an optional member and an enum value.
      expect(registry.project(noteType, written), isEmpty);
      registry.install(descriptor(), schema: narrowed());
      final diagnostics = registry.project(noteType, written);
      expect(diagnostics.map((d) => d['instanceLocation']), [
        '/size',
        '/state',
      ]);
      expect(diagnostics.first['message'], contains('"size"'));
      expect(
        diagnostics.last['schemaLocation'],
        'https://work.example/schemas/note#/properties/state/type',
      );
      expect(
        () => registry.project('https://work.example/types/none', written),
        throwsArgumentError,
      );
    });
  });

  test('the authority pins installed Types and lists them', () {
    final authority = memoryAuthority(TestClock());
    final inventory = authority.typeInventory().body;
    expectSchema(inventory, 'typesInventory');
    expect((inventory['items']! as List), hasLength(4));
    authority.close();
  });
}
