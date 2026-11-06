import 'dart:convert';

import 'package:meta/meta.dart';

/// One frame of a `text/event-stream`: a dispatched message, or a
/// reconnection-delay suggestion.
@immutable
sealed class SseFrame {
  const SseFrame._();
}

/// A dispatched Server-Sent Event.
final class SseMessage extends SseFrame {
  /// A message of [event] carrying [data].
  const SseMessage({required this.event, required this.data, this.id})
    : super._();

  /// The event type; `message` when the stream named none.
  final String event;

  /// The data lines joined with line feeds.
  final String data;

  /// The last event ID the stream had set when this message was dispatched.
  ///
  /// This records transport progress only; it says nothing about whether
  /// the consumer applied the message.
  final String? id;

  @override
  bool operator ==(Object other) =>
      other is SseMessage &&
      other.event == event &&
      other.data == data &&
      other.id == id;

  @override
  int get hashCode => Object.hash(event, data, id);

  @override
  String toString() => 'SseMessage($event, id: $id)';
}

/// A `retry` field: the server's suggested reconnection delay.
final class SseRetry extends SseFrame {
  /// A suggestion of [delay].
  const SseRetry(this.delay) : super._();

  /// The suggested delay.
  final Duration delay;

  @override
  bool operator ==(Object other) => other is SseRetry && other.delay == delay;

  @override
  int get hashCode => delay.hashCode;
}

final RegExp _digits = RegExp(r'^[0-9]+$');

/// Decodes a UTF-8 `text/event-stream` body into frames, following the
/// WHATWG event-stream interpretation.
///
/// A message is dispatched only by the blank line that ends it; a message
/// cut off by the end of the stream is discarded, never dispatched.
Stream<SseFrame> decodeSse(Stream<List<int>> bytes) async* {
  final data = StringBuffer();
  var eventType = '';
  String? lastEventId;
  var first = true;
  await for (var line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (first) {
      first = false;
      if (line.startsWith('﻿')) line = line.substring(1);
    }
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final text = data.toString();
        yield SseMessage(
          event: eventType.isEmpty ? 'message' : eventType,
          data: text.substring(0, text.length - 1),
          id: lastEventId,
        );
      }
      data.clear();
      eventType = '';
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        eventType = value;
      case 'data':
        data
          ..write(value)
          ..write('\n');
      case 'id':
        if (!value.contains('\u0000')) lastEventId = value;
      case 'retry':
        if (_digits.hasMatch(value)) {
          yield SseRetry(Duration(milliseconds: int.parse(value)));
        }
    }
  }
}
