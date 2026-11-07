// The client held to the supervisor's own OpenAPI description
// (fixtures/openapi.json): every operation and parameter it sends exists,
// every fixture has the shape of the response it stands for, and no field the
// description makes optional is one the client requires.
import 'package:gc_api/gc_api.dart';
import 'package:test/test.dart';

import 'support.dart';

typedef Json = Map<String, Object?>;

final Json spec = fixtureJson('openapi.json')! as Json;
final Json schemas = (spec['components']! as Json)['schemas']! as Json;

/// The operation [method] [path] of the description.
Json operation(String method, String path) {
  final item = (spec['paths']! as Json)[path] as Json?;
  expect(item, isNotNull, reason: '$path is not in the description');
  final op = item![method] as Json?;
  expect(op, isNotNull, reason: '$method $path is not in the description');
  return op!;
}

Set<String> parameters(Json op, String location) => {
  for (final p in (op['parameters'] as List<Object?>? ?? const []).cast<Json>())
    if (p['in'] == location) p['name']! as String,
};

/// The schema [schema] stands for: a reference followed, and a discriminated
/// event envelope read as the envelope every variant shares.
Json resolve(Json schema) {
  final ref = schema[r'$ref'];
  if (ref is! String) return schema;
  final name = ref.split('/').last;
  if (name == 'TypedEventStreamEnvelope') {
    return schemas['EventStreamEnvelope']! as Json;
  }
  return resolve(schemas[name]! as Json);
}

/// The schema of the 200 response of [op].
Json okBody(Json op) {
  final content =
      ((op['responses']! as Json)['200']! as Json)['content']! as Json;
  return resolve((content['application/json']! as Json)['schema']! as Json);
}

/// Every place in [value] where it departs from [schema]: a member the
/// schema does not name, or a required member it lacks.
List<String> departures(Object? value, Json schema, String path) {
  schema = resolve(schema);
  final found = <String>[];
  if (value is Map<String, Object?>) {
    final properties = schema['properties'] as Json?;
    if (properties == null) return found;
    for (final name in (schema['required'] as List<Object?>? ?? const [])) {
      if (!value.containsKey(name)) found.add('$path.$name is required');
    }
    for (final MapEntry(:key, value: member) in value.entries) {
      final property = properties[key] as Json?;
      if (property == null) {
        found.add('$path.$key is not in the schema');
      } else {
        found.addAll(departures(member, property, '$path.$key'));
      }
    }
  } else if (value is List<Object?>) {
    if (schema['items'] case final Json items) {
      for (final (i, item) in value.indexed) {
        found.addAll(departures(item, items, '$path[$i]'));
      }
    }
  }
  return found;
}

/// [value] once with each optional member the schema allows it to lack
/// removed, at every depth, with the path of what was removed.
Iterable<(String, Object?)> withoutEachOptional(
  Object? value,
  Json schema,
  String path,
) sync* {
  schema = resolve(schema);
  if (value is Map<String, Object?>) {
    final properties = schema['properties'] as Json?;
    if (properties == null) return;
    final required = {...?(schema['required'] as List<Object?>?)};
    for (final MapEntry(:key, value: member) in value.entries) {
      if (!required.contains(key)) {
        yield ('$path.$key', {...value}..remove(key));
      }
      for (final (inner, changed) in withoutEachOptional(
        member,
        properties[key]! as Json,
        '$path.$key',
      )) {
        yield (inner, {...value, key: changed});
      }
    }
  } else if (value is List<Object?>) {
    if (schema['items'] case final Json items) {
      for (final (i, item) in value.indexed) {
        for (final (inner, changed) in withoutEachOptional(
          item,
          items,
          '$path[$i]',
        )) {
          yield (inner, [...value]..[i] = changed);
        }
      }
    }
  }
}

/// What the client reads, by fixture: the operation, its 200 body, and the
/// client's reader of that body.
final reads = <String, (String, String, void Function(Object?))>{
  'health.json': ('get', '/health', SupervisorHealth.fromJson),
  'cities.json': (
    'get',
    '/v0/cities',
    (json) => [
      for (final item in (json! as Json)['items']! as List<Object?>)
        CityInfo.fromJson(item),
    ],
  ),
  'status.json': ('get', '/v0/city/{cityName}/status', CityStatus.fromJson),
  'events.json': ('get', '/v0/city/{cityName}/events', EventPage.fromJson),
  'sessions.json': (
    'get',
    '/v0/city/{cityName}/sessions',
    SessionPage.fromJson,
  ),
  'session.json': (
    'get',
    '/v0/city/{cityName}/session/{id}',
    GcSession.fromJson,
  ),
  'pending.json': ('get', '/v0/city/{cityName}/pending', PendingPage.fromJson),
  'session_pending.json': (
    'get',
    '/v0/city/{cityName}/session/{id}/pending',
    SessionPending.fromJson,
  ),
};

void main() {
  group('every fixture has the shape of its response', () {
    for (final MapEntry(key: name, value: (method, path, _)) in reads.entries) {
      test(name, () {
        expect(
          departures(fixtureJson(name), okBody(operation(method, path)), r'$'),
          isEmpty,
        );
      });
    }
    test('problem.json', () {
      expect(
        departures(
          fixtureJson('problem.json'),
          schemas['ErrorModel']! as Json,
          r'$',
        ),
        isEmpty,
      );
    });
  });

  group('the client reads a body that lacks any one optional member', () {
    for (final MapEntry(key: name, value: (method, path, read))
        in reads.entries) {
      test(name, () {
        final body = okBody(operation(method, path));
        final variants = withoutEachOptional(fixtureJson(name), body, r'$');
        expect(variants, isNotEmpty);
        for (final (removed, variant) in variants) {
          expect(() => read(variant), returnsNormally, reason: removed);
        }
      });
    }
  });

  test('the problem reader requires no member', () {
    expect(GcProblem.fromJson(const <String, Object?>{}).code, isNull);
    expect((schemas['ErrorModel']! as Json)['required'], isNull);
  });

  test('the event list takes the filters the client sends', () {
    final op = operation('get', '/v0/city/{cityName}/events');
    expect(
      parameters(op, 'query'),
      containsAll(['cursor', 'limit', 'type', 'actor', 'since']),
    );
  });

  test('the session list takes the filters the client sends', () {
    final op = operation('get', '/v0/city/{cityName}/sessions');
    expect(
      parameters(op, 'query'),
      containsAll(['cursor', 'limit', 'state', 'template']),
    );
  });

  test('the event stream resumes by after_seq and names the events the '
      'client reads', () {
    final op = operation('get', '/v0/city/{cityName}/events/stream');
    expect(parameters(op, 'query'), contains('after_seq'));
    expect(parameters(op, 'header'), contains('Last-Event-ID'));
    final content =
        ((op['responses']! as Json)['200']! as Json)['content']! as Json;
    final variants =
        (((content['text/event-stream']! as Json)['schema']! as Json)['items']!
                as Json)['oneOf']!
            as List<Object?>;
    final names = {
      for (final variant in variants.cast<Json>())
        ((variant['properties']! as Json)['event']! as Json)['const'],
    };
    expect(names, {'event', 'heartbeat'});
  });
}
