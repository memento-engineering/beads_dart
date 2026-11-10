import 'dart:convert';

import 'package:gc_client/gc_client.dart';
import 'package:test/test.dart';

/// A `dependencies` row as `gc bd show --json` prints it: the whole
/// depended-on bead plus `dependency_type`.
const showRow =
    '{"id": "b-2", "title": "T", "status": "open", "issue_type": "task", '
    '"metadata": {"k": "v"}, "dependency_type": "blocks"}';

/// A `dependencies` row as `gc bd list --json` prints it: an edge row with
/// no status.
const listRow =
    '{"issue_id": "b-1", "depends_on_id": "b-2", "type": "blocks", '
    '"created_at": "2026-10-25T10:00:00Z", "created_by": "seat", '
    '"metadata": "{}"}';

/// Bead `b-1` as gc prints it, with [dependencies] as its `dependencies`
/// JSON text, or no `dependencies` key when it is null.
Bead? bead({String? dependencies}) => Bead.fromJson(
  jsonDecode(
    '{"id": "b-1", "title": "A bead", "status": "open"'
    '${dependencies == null ? '' : ', "dependencies": $dependencies'}}',
  ),
);

void main() {
  group('BeadDependency.fromJson', () {
    test('reads the show shape: id, status and dependency_type', () {
      expect(
        BeadDependency.fromJson(jsonDecode(showRow)),
        const BeadDependency(id: 'b-2', status: 'open', type: 'blocks'),
      );
    });

    test('reads the list shape: depends_on_id and type, status empty', () {
      final row = BeadDependency.fromJson(jsonDecode(listRow));
      expect(row, const BeadDependency(id: 'b-2', type: 'blocks'));
      expect(row!.status, '');
    });

    test('reads a row carrying both id and depends_on_id as the show '
        'shape', () {
      expect(
        BeadDependency.fromJson(
          jsonDecode(
            '{"id": "b-3", "depends_on_id": "b-2", "status": "closed", '
            '"type": "related", "dependency_type": "blocks"}',
          ),
        ),
        const BeadDependency(id: 'b-3', status: 'closed', type: 'blocks'),
      );
    });

    test('reads a non-string status, type or dependency_type as empty', () {
      expect(
        BeadDependency.fromJson(
          jsonDecode('{"id": "b-2", "status": 1, "dependency_type": true}'),
        ),
        const BeadDependency(id: 'b-2'),
      );
      expect(
        BeadDependency.fromJson(
          jsonDecode('{"depends_on_id": "b-2", "type": ["blocks"]}'),
        ),
        const BeadDependency(id: 'b-2'),
      );
    });

    for (final text in [
      'null',
      '"b-2"',
      '1',
      '[]',
      '{}',
      '{"id": ""}',
      '{"id": 2}',
      '{"depends_on_id": ""}',
      '{"depends_on_id": 2}',
      '{"title": "no id"}',
    ]) {
      test('is null for $text', () {
        expect(BeadDependency.fromJson(jsonDecode(text)), isNull);
      });
    }
  });

  group('BeadDependency equality', () {
    const a = BeadDependency(id: 'b-2', status: 'open', type: 'blocks');

    test('equal fields make equal values and hash codes', () {
      const b = BeadDependency(id: 'b-2', status: 'open', type: 'blocks');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('any one differing field makes them unequal', () {
      expect(
        a,
        isNot(const BeadDependency(id: 'b-3', status: 'open', type: 'blocks')),
      );
      expect(
        a,
        isNot(
          const BeadDependency(id: 'b-2', status: 'closed', type: 'blocks'),
        ),
      );
      expect(
        a,
        isNot(const BeadDependency(id: 'b-2', status: 'open', type: 'related')),
      );
    });

    test('toString names all three fields', () {
      expect(a.toString(), 'BeadDependency(b-2, status: open, type: blocks)');
    });
  });

  group('Bead.fromJson dependencies', () {
    test('reads an open and a closed blocks row in gc\'s order', () {
      final parsed = bead(
        dependencies:
            '[$showRow, {"id": "b-3", "title": "U", "status": "closed", '
            '"issue_type": "task", "metadata": {}, '
            '"dependency_type": "blocks"}]',
      );
      expect(parsed!.dependencies, const [
        BeadDependency(id: 'b-2', status: 'open', type: 'blocks'),
        BeadDependency(id: 'b-3', status: 'closed', type: 'blocks'),
      ]);
    });

    test('reads a list-shape edge row', () {
      expect(bead(dependencies: '[$listRow]')!.dependencies, const [
        BeadDependency(id: 'b-2', type: 'blocks'),
      ]);
    });

    for (final (name, text) in [
      ('absent', null),
      ('null', 'null'),
      ('a string', '"b-2"'),
      ('a number', '3'),
      ('an object', '{"id": "b-2"}'),
    ]) {
      test('returns the bead with none when dependencies is $name', () {
        final parsed = bead(dependencies: text);
        expect(parsed, isNotNull);
        expect(parsed!.id, 'b-1');
        expect(parsed.title, 'A bead');
        expect(parsed.status, 'open');
        expect(parsed.dependencies, isEmpty);
      });
    }

    test('keeps exactly the well-formed rows, in gc\'s order', () {
      final parsed = bead(
        dependencies:
            '[null, 1, "s", [], {}, {"id": ""}, {"id": 2}, '
            '{"depends_on_id": ""}, {"title": "x"}, $showRow, 7, '
            '{"issue_id": "b-1", "depends_on_id": "b-4", "type": "blocks"}]',
      );
      expect(parsed, isNotNull);
      expect(parsed!.dependencies, const [
        BeadDependency(id: 'b-2', status: 'open', type: 'blocks'),
        BeadDependency(id: 'b-4', type: 'blocks'),
      ]);
    });

    test('leaves dependents, dependency_count and dependent_count unread', () {
      final parsed = Bead.fromJson(
        jsonDecode(
          '{"id": "b-1", "dependents": [{"id": "b-9", '
          '"dependency_type": "blocks"}], "dependency_count": 1, '
          '"dependent_count": 1}',
        ),
      );
      expect(parsed, isNotNull);
      expect(parsed!.dependencies, isEmpty);
    });

    test('a bead without an id is still null', () {
      expect(
        Bead.fromJson(
          jsonDecode('{"title": "no id", "dependencies": [$showRow]}'),
        ),
        isNull,
      );
    });

    test('a bead built without dependencies has none', () {
      expect(const Bead(id: 'b-1').dependencies, isEmpty);
    });
  });
}
