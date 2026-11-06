@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bdp/bdp.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// Launches the deterministic `bdptest` reference server with an advertised
/// Read profile on an ephemeral port and reads it through [ScopeClient].
///
/// Set `BDPTEST_MAIN` to the server's built `dist/main.js`. Without node on
/// the PATH, or without that file, the group is skipped rather than failed.
void main() {
  final serverMain = Platform.environment['BDPTEST_MAIN'];
  final skip = !_nodeAvailable()
      ? 'node is not on the PATH'
      : serverMain == null || !File(serverMain).existsSync()
      ? 'BDPTEST_MAIN does not name the bdptest dist/main.js'
      : null;

  group('bdptest Read server', () {
    final domain = fixture('reference-domain/reference-domain.json');
    late Directory workspace;
    late Process server;
    late http.Client httpClient;
    late String scope;
    late ScopeClient client;

    setUpAll(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      workspace = await Directory.systemTemp.createTemp('bdptest-');
      final config = File('${workspace.path}/config.json')
        ..writeAsStringSync(
          jsonEncode({
            'server': {
              'host': '127.0.0.1',
              'port': port,
              'advertisedProfile': 'read',
            },
          }),
        );
      server = await Process.start('node', [
        serverMain!,
        '--serve',
        '--config',
        config.path,
      ]);
      final started = Completer<void>();
      server.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.contains('"server.started"') && !started.isCompleted) {
              started.complete();
            }
          });
      unawaited(server.stdout.drain<void>());
      unawaited(
        server.exitCode.then((code) {
          if (!started.isCompleted) {
            started.completeError(StateError('bdptest exited with $code'));
          }
        }),
      );
      await started.future.timeout(const Duration(seconds: 30));
      scope = 'http://127.0.0.1:$port/local-test/';
      httpClient = http.Client();
      client = await ScopeClient.discover(
        Uri.parse(scope),
        httpClient: httpClient,
      );
    });

    tearDownAll(() async {
      httpClient.close();
      server.kill();
      await server.exitCode;
      await workspace.delete(recursive: true);
    });

    Object canonical(Object reference) => switch (reference) {
      final String uri when uri.startsWith('beads/') => '$scope$uri',
      final String uri => uri,
      final Map<String, Object?> pinned => {
        'uri': canonical(pinned['uri']!),
        'revision': pinned['revision'],
      },
      _ => throw ArgumentError(reference),
    };

    test('discovery advertises the Read profile at the Scope', () {
      expect(client.discovery.profile, Profile.read);
      expect(client.discovery.scope, scope);
      expect(client.discovery.beads, '${scope}beads/');
      expect(client.operations, isNull);
      expect(client.discovery.limits?.page?.maximumItems, isPositive);
    });

    test('the Type inventory is the fixture domain', () async {
      final summaries = <Map<String, Object?>>[];
      var page = await client.types(limit: 3);
      summaries.addAll(page.items.map((s) => s.toJson()));
      for (var next = page.next; next != null; next = page.next) {
        page = await client.nextTypes(next);
        summaries.addAll(page.items.map((s) => s.toJson()));
      }
      final expected = [
        ...(domain['beadTypes']! as List<Object?>),
        ...(domain['linkTypes']! as List<Object?>),
      ].cast<Map<String, Object?>>();
      int byId(Map<String, Object?> a, Map<String, Object?> b) =>
          (a['id']! as String).compareTo(b['id']! as String);
      expect(summaries, equals([...expected]..sort(byId)));
    });

    test('external-endpoint Links read back byte for byte', () async {
      for (final entry
          in (domain['externalEndpointLinks']! as List<Object?>)
              .cast<Map<String, Object?>>()) {
        final link = await client.readLink(entry['localId']! as String);
        expect(link.id, '$scope${entry['localId']}');
        expect(link.type, entry['type']);
        expect(link.revision.value, entry['revision']);
        expect(link.properties, equals(entry['properties']));
        expect(link.source.toJson(), equals(canonical(entry['source']!)));
        expect(link.target.toJson(), equals(canonical(entry['target']!)));
        expect(link.attribution?.toJson(), entry['attribution']);
      }
    });

    test(
      'incident Links of the shared Bead include every fixture Link',
      () async {
        final inbound = await client
            .allIncidentLinks('beads/demo-f', direction: LinkDirection.inbound)
            .map((link) => link.id)
            .toList();
        expect(
          inbound,
          containsAll([
            '${scope}links/external-source',
            '${scope}links/pinned-local',
            '${scope}links/ZZ-collation',
          ]),
        );
        final outbound = await client
            .allIncidentLinks('beads/demo-f', direction: LinkDirection.outbound)
            .map((link) => link.id)
            .toList();
        expect(outbound, contains('${scope}links/external-target'));
      },
    );

    test('Bead pages walk the fixture domain in canonical-uri order', () async {
      final beads = await client.allBeads(const BeadQuery(limit: 2)).toList();
      final ids = [for (final bead in beads) bead.id];
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, equals([...ids]..sort()));

      // Every Bead is of a fixture Bead Type, and every in-Scope endpoint
      // the fixture's Links name is served and reads back as walked.
      final beadTypes = {
        for (final type
            in (domain['beadTypes']! as List<Object?>)
                .cast<Map<String, Object?>>())
          type['id'],
      };
      for (final bead in beads) {
        expect(beadTypes, contains(bead.type), reason: bead.id);
      }
      final endpoints = {
        for (final link
            in (domain['externalEndpointLinks']! as List<Object?>)
                .cast<Map<String, Object?>>())
          for (final end in [link['source']!, link['target']!])
            if (end case final String local when local.startsWith('beads/'))
              local,
      };
      expect(endpoints, isNotEmpty);
      for (final local in endpoints) {
        final read = await client.readBead(local);
        expect(read.id, '$scope$local');
        expect(beads, contains(read));
      }
    });

    test('a Selector narrows the Link collection to the fixture', () async {
      const blocksType = 'https://work.example/types/blocks';
      final blocks = await client
          .allLinks(
            LinkQuery(selector: Selector('\$[?@.type == "$blocksType"]')),
          )
          .toList();
      expect(blocks.every((l) => l.type == blocksType), isTrue);
      final expected = [
        for (final link
            in (domain['externalEndpointLinks']! as List<Object?>)
                .cast<Map<String, Object?>>())
          if (link['type'] == blocksType) '$scope${link['localId']}',
      ];
      expect(expected, isNotEmpty);
      expect(blocks.map((l) => l.id), containsAll(expected));
    });

    test('a miss is the uniform not-found problem', () async {
      await expectLater(
        client.readBead('beads/does-not-exist'),
        throwsA(
          isA<BdpProblemException>()
              .having((e) => e.code, 'code', ProblemCodes.resourceNotFound)
              .having((e) => e.status, 'status', 404),
        ),
      );
    });
  }, skip: skip);
}

bool _nodeAvailable() {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
