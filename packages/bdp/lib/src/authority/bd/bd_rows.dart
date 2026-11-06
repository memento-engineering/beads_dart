/// One whole read of a bd store, `bd list --json`, as the bd authority
/// carries it.
///
/// **What a read carries.** `bd list --json` leaves a field out of a row
/// when it is empty, so a row without a field does not by itself say
/// whether the bead's field is empty or the list path does not carry it.
/// A field bd omits when empty ([bdOmittedWhenEmpty]) is carried, for every
/// row of one read, only when that read evidences it: at least one row of
/// the same call holds a value for it ([bdHolds]). Then a row without a
/// value holds it empty. A field no row of the read holds a value for is
/// left out of every bead, so it reads unknown, never empty. The evidence is
/// taken afresh on every read. Dependencies are carried by their own rule:
/// a row that lists none carries none only when bd counts none.
library;

import '../json_text.dart';

/// The arguments of the one read: every bead bd holds, closed ones and
/// gates included, flat, unlimited, in id order, as JSON.
const bdListArguments = [
  'list',
  '--all',
  '--include-gates',
  '--flat',
  '--limit',
  '0',
  '--sort',
  'id',
  '--json',
];

/// The control query an empty read is checked against: the store's
/// configuration, which has rows in every store bd can open.
const bdControlArguments = ['config', 'list', '--json'];

/// The fields a row carries when it has them.
const bdScalarFields = [
  'issue_type',
  'status',
  'priority',
  'assignee',
  'updated_at',
];

/// The text fields bd omits when empty: carried as empty text when the
/// read evidences them.
const bdTextFields = [
  'title',
  'description',
  'design',
  'acceptance_criteria',
  'notes',
];

/// The other fields bd omits when empty: carried as null (`metadata` as an
/// empty map) when the read evidences them.
const bdOptionalFields = ['external_ref', 'await_id', 'close_reason'];

/// The fields `bd list --json` leaves out of a row when they are empty.
const bdOmittedWhenEmpty = {...bdTextFields, ...bdOptionalFields, 'metadata'};

/// Whether [value], a field of a row, evidences the list path carries its
/// field: anything but null and an empty text, map or list.
bool bdHolds(Object? value) => switch (value) {
  null => false,
  final String text => text.isNotEmpty,
  final Map<Object?, Object?> map => map.isNotEmpty,
  final List<Object?> list => list.isNotEmpty,
  _ => true,
};

/// The fields of [bdOmittedWhenEmpty] that [rows], one read, evidence.
Set<String> bdEvidencedFields(List<Object?> rows) => {
  for (final row in rows)
    if (row is Map<String, Object?>)
      for (final field in bdOmittedWhenEmpty)
        if (bdHolds(row[field])) field,
};

/// One bd dependency: [holder] depends on [target] as [type].
typedef BdDependency = ({String holder, String type, String target});

/// A whole read projected: each bead's properties by its bd id, in id
/// order, and every dependency the read lists.
typedef BdRead = ({
  Map<String, JsonMap> beads,
  List<BdDependency> dependencies,
});

/// [rows], one whole `bd list --json`, projected.
///
/// Throws a [FormatException] naming the row's index for a row that is no
/// object, names no bead, or lists a dependency that names no target or
/// type: a read that cannot be carried whole is not carried at all.
BdRead projectBdRows(List<Object?> rows) {
  final evidenced = bdEvidencedFields(rows);
  final beads = <String, JsonMap>{};
  final dependencies = <BdDependency>[];
  for (final (index, row) in rows.indexed) {
    if (row is! Map<String, Object?>) {
      throw FormatException('bd list row $index is no object');
    }
    final id = row['id'];
    if (id is! String || id.isEmpty) {
      throw FormatException('bd list row $index names no bead');
    }
    final properties = <String, Object?>{
      'id': id,
      for (final key in bdScalarFields)
        if (row.containsKey(key)) key: row[key],
      for (final key in bdTextFields)
        if (bdHolds(row[key]) || evidenced.contains(key)) key: row[key] ?? '',
      for (final key in bdOptionalFields)
        if (bdHolds(row[key]) || evidenced.contains(key)) key: row[key],
    };
    if (bdHolds(row['metadata']) || evidenced.contains('metadata')) {
      if (_metadata(row['metadata']) case final metadata?) {
        properties['metadata'] = metadata;
      }
    }
    final listed = row['dependencies'];
    if (listed == null) {
      if (row['dependency_count'] == 0) properties['dependencies'] = const [];
    } else if (listed is List<Object?>) {
      final carried = <JsonMap>[];
      for (final entry in listed) {
        final target = entry is Map<String, Object?>
            ? entry['depends_on_id']
            : null;
        final type = entry is Map<String, Object?> ? entry['type'] : null;
        if (target is! String || target.isEmpty) {
          throw FormatException(
            'bd list row $index lists a dependency that names no target',
          );
        }
        if (type is! String || type.isEmpty) {
          throw FormatException(
            'bd list row $index lists a dependency that names no type',
          );
        }
        carried.add({'depends_on_id': target, 'type': type});
        dependencies.add((holder: id, type: type, target: target));
      }
      properties['dependencies'] = carried;
    }
    beads[id] = properties;
  }
  return (beads: beads, dependencies: dependencies);
}

/// The metadata a row carries: an empty map for none, and nothing for a map
/// holding a number a Scope cannot store, so one bead's metadata never
/// stops the Scope from taking every other bead.
JsonMap? _metadata(Object? metadata) => switch (metadata) {
  null => const {},
  final Map<String, Object?> map when _storable(map) => map,
  _ => null,
};

bool _storable(Object? value) => switch (value) {
  final num number => isAdmissibleNumber(number),
  final Map<String, Object?> map => map.values.every(_storable),
  final List<Object?> list => list.every(_storable),
  _ => true,
};
