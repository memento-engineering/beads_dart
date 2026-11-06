import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

Future<List<SseFrame>> decode(List<String> chunks) =>
    decodeSse(Stream.fromIterable(chunks.map(utf8.encode))).toList();

void main() {
  test('frames a canned change-group stream from the fixture', () async {
    final live =
        (fixture('transactional/changefeed.json')['livePublicationExamples']!
                    as List<Object?>)
                .first!
            as Map<String, Object?>;
    final sse = live['sse']! as Map<String, Object?>;
    final text =
        ': keepalive\n'
        'retry: 2500\n'
        'id: ${sse['id']}\n'
        'event: ${sse['event']}\n'
        'data: ${jsonEncode(sse['data'])}\n'
        '\n';
    // Split mid-line and mid-codepoint boundary to exercise chunking.
    final bytes = utf8.encode(text);
    final frames = await decodeSse(
      Stream.fromIterable([bytes.sublist(0, 37), bytes.sublist(37)]),
    ).toList();
    expect(frames, [
      const SseRetry(Duration(milliseconds: 2500)),
      isA<SseMessage>()
          .having((m) => m.event, 'event', 'change-group')
          .having((m) => m.id, 'id', sse['id']),
    ]);
    final group = ChangeGroup.fromJson(
      jsonDecode((frames.last as SseMessage).data),
    );
    expect(group.checkpoint.value, sse['id']);
  });

  test('joins multi-line data and accepts every line ending', () async {
    final frames = await decode(['data: a\r\ndata:b\rdata\n\n']);
    expect(frames, [const SseMessage(event: 'message', data: 'a\nb\n')]);
  });

  test('a CRLF split across chunks is one line ending', () async {
    final frames = await decode(['id: 1\r', '\ndata: x\r\n\r\n']);
    expect(frames, [const SseMessage(event: 'message', data: 'x', id: '1')]);
  });

  test('strips a leading byte-order mark', () async {
    final frames = await decode(['﻿event: e\ndata: d\n\n']);
    expect(frames, [const SseMessage(event: 'e', data: 'd')]);
  });

  test('ignores comments, unknown fields and a block without data', () async {
    final frames = await decode([
      ': comment\nevent: lonely\n\nfoo: bar\ndata: kept\n\n',
    ]);
    expect(frames, [const SseMessage(event: 'message', data: 'kept')]);
  });

  test('the last event ID persists across messages', () async {
    final frames = await decode(['id: 7\ndata: a\n\ndata: b\n\n']);
    expect(frames, [
      const SseMessage(event: 'message', data: 'a', id: '7'),
      const SseMessage(event: 'message', data: 'b', id: '7'),
    ]);
  });

  test(
    'a message cut off by the end of the stream is not dispatched',
    () async {
      final frames = await decode([
        'id: ckpt-43\ndata: {}\n\n',
        'id: ckpt-44\nevent: change-group\ndata: {"partial":',
      ]);
      expect(frames, [
        const SseMessage(event: 'message', data: '{}', id: 'ckpt-43'),
      ]);
    },
  );

  test('a non-numeric retry is ignored', () async {
    expect(await decode(['retry: soon\n\n']), isEmpty);
  });
}
