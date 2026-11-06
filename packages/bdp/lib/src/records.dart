import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';
import 'tokens.dart';

/// The two Resource kinds; also what a Type Descriptor describes.
enum ResourceKind {
  /// A Bead.
  bead,

  /// A Link.
  link;

  /// Decodes a kind from its wire spelling.
  static ResourceKind fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (kind) => kind.name);

  /// The wire spelling.
  String toJson() => name;
}

/// Which end of a Link a value names.
enum LinkEndpoint {
  /// The Link's source.
  source,

  /// The Link's target.
  target;

  /// Decodes an endpoint from its wire spelling.
  static LinkEndpoint fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (endpoint) => endpoint.name);

  /// The wire spelling.
  String toJson() => name;
}

/// The basis a realization records for a carried [Attribution].
enum AttributionStatus {
  /// The principal was supplied by the writer of the version.
  claimed,

  /// The principal is carried from data whose relationship to the version
  /// cannot be established.
  unknown;

  /// Decodes a status from its wire spelling.
  static AttributionStatus fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (status) => status.name);

  /// The wire spelling.
  String toJson() => name;
}

/// Per-version carried attribution: data, not evidence of who acted.
@immutable
final class Attribution {
  /// Attribution to [principal] with [status].
  const Attribution({required this.principal, required this.status});

  /// Decodes an attribution object.
  factory Attribution.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return Attribution(
      principal: reader.string('principal'),
      status: reader.decode('status', AttributionStatus.fromJson),
    );
  }

  /// The opaque principal the version is attributed to.
  final String principal;

  /// The realization's basis for [principal].
  final AttributionStatus status;

  /// The wire form.
  JsonObject toJson() => {'principal': principal, 'status': status.toJson()};

  @override
  bool operator ==(Object other) =>
      other is Attribution &&
      other.principal == principal &&
      other.status == status;

  @override
  int get hashCode => Object.hash(principal, status);

  @override
  String toString() => 'Attribution($principal, ${status.name})';
}

/// How BDP points at anything: a URI, or a URI pinned to the revision it was
/// made against.
///
/// Equality is structural, pin included, so a decoded value re-encodes
/// exactly. Graph identity — incident traversal, endpoint comparison — uses
/// the URI alone; see [sameTarget].
@immutable
sealed class Reference {
  const Reference._();

  /// Decodes a Reference: a string is a bare URI, an object is pinned.
  factory Reference.fromJson(Object? json, [String path = '']) =>
      switch (json) {
        final String uri => UriReference(uri),
        final Map<String, Object?> _ => PinnedReference.fromJson(json, path),
        _ => throw FormatException('$path: expected a URI or a pinned object'),
      };

  /// The referenced URI, exactly as stored.
  String get uri;

  /// Whether this and [other] reference the same URI, ignoring any pin.
  bool sameTarget(Reference other) => uri == other.uri;

  /// The wire form: a string, or a pinned object.
  Object toJson();
}

/// A bare URI reference.
final class UriReference extends Reference {
  /// References [uri].
  const UriReference(this.uri) : super._();

  @override
  final String uri;

  @override
  String toJson() => uri;

  @override
  bool operator ==(Object other) => other is UriReference && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => uri;
}

/// A reference pinned to the revision it was made against. The pin is
/// recorded provenance, stored and echoed byte for byte.
final class PinnedReference extends Reference {
  /// References [uri] as of [revision].
  const PinnedReference(this.uri, this.revision) : super._();

  /// Decodes a pinned reference object.
  factory PinnedReference.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return PinnedReference(
      reader.string('uri'),
      reader.decode('revision', Revision.fromJson),
    );
  }

  @override
  final String uri;

  /// The pinned revision token.
  final Revision revision;

  @override
  JsonObject toJson() => {'uri': uri, 'revision': revision.toJson()};

  @override
  bool operator ==(Object other) =>
      other is PinnedReference &&
      other.uri == uri &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(uri, revision);

  @override
  String toString() => '$uri@$revision';
}

/// The identity of one Resource version: canonical URL, Type and revision.
@immutable
final class ResourceIdentity {
  /// An identity.
  const ResourceIdentity({
    required this.id,
    required this.type,
    required this.revision,
  });

  /// Decodes a Resource identity.
  factory ResourceIdentity.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return ResourceIdentity(
      id: reader.string('id'),
      type: reader.string('type'),
      revision: reader.decode('revision', Revision.fromJson),
    );
  }

  /// The absolute canonical Resource URL.
  final String id;

  /// The declared Type ID.
  final String type;

  /// The revision this identity names.
  final Revision revision;

  /// The wire form.
  JsonObject toJson() => {
    'id': id,
    'type': type,
    'revision': revision.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ResourceIdentity &&
      other.id == id &&
      other.type == type &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(id, type, revision);

  @override
  String toString() => 'ResourceIdentity($id@$revision)';
}

/// The canonical identity a deletion reports.
@immutable
final class DeletedIdentity {
  /// A deleted identity of [resourceKind].
  const DeletedIdentity({required this.resourceKind, required this.resource});

  /// Decodes a deleted identity.
  factory DeletedIdentity.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return DeletedIdentity(
      resourceKind: reader.decode('resourceKind', ResourceKind.fromJson),
      resource: reader.decode('resource', ResourceIdentity.fromJson),
    );
  }

  /// Whether a Bead or a Link was deleted.
  final ResourceKind resourceKind;

  /// The deleted Resource's identity at its final live revision.
  final ResourceIdentity resource;

  /// The wire form.
  JsonObject toJson() => {
    'resourceKind': resourceKind.toJson(),
    'resource': resource.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is DeletedIdentity &&
      other.resourceKind == resourceKind &&
      other.resource == resource;

  @override
  int get hashCode => Object.hash(resourceKind, resource);
}

/// A Link's immutable identity and Type, as graph Events carry it.
@immutable
final class TypedLinkReference {
  /// A typed reference to the Link [id].
  const TypedLinkReference({required this.id, required this.type});

  /// Decodes a typed Link reference.
  factory TypedLinkReference.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return TypedLinkReference(
      id: reader.string('id'),
      type: reader.string('type'),
    );
  }

  /// The Link's canonical URL.
  final String id;

  /// The Link's Type ID.
  final String type;

  /// The wire form.
  JsonObject toJson() => {'id': id, 'type': type};

  @override
  bool operator ==(Object other) =>
      other is TypedLinkReference && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);
}

/// One page of a paginated collection: complete items plus the
/// server-generated continuation.
///
/// An empty page with a non-null [next] is not the end of the collection;
/// only `next == null` is.
@immutable
final class Page<T> {
  /// A page of [items] continuing at [next].
  Page({required List<T> items, required this.next})
    : items = List.unmodifiable(items);

  /// Decodes a page whose items are decoded by [decodeItem].
  factory Page.fromJson(
    Object? json,
    String path,
    T Function(Object? value, String path) decodeItem,
  ) {
    final reader = JsonReader.of(json, path);
    if (!reader.has('next')) {
      throw FormatException('${reader.at('next')}: required member is missing');
    }
    return Page(
      items: reader.list('items', decodeItem),
      next: reader.optionalString('next'),
    );
  }

  /// The items of this page, in the authority's advertised order.
  final List<T> items;

  /// The absolute URL of the next page, or `null` after the final page.
  final String? next;

  /// Whether this is the final page.
  bool get isLast => next == null;

  /// The wire form, encoding items with [encodeItem].
  JsonObject toJson(Object? Function(T item) encodeItem) => {
    'items': [for (final item in items) encodeItem(item)],
    'next': next,
  };

  @override
  bool operator ==(Object other) =>
      other is Page<T> &&
      other.next == next &&
      ListEquality<T>().equals(other.items, items);

  @override
  int get hashCode => Object.hash(next, ListEquality<T>().hash(items));
}

/// A canonical Bead or Link record.
@immutable
sealed class ResourceRecord {
  const ResourceRecord._();

  /// Decodes a Bead or Link record; a record with endpoints is a Link.
  factory ResourceRecord.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return reader.has('source') || reader.has('target')
        ? LinkRecord.fromJson(json, path)
        : BeadRecord.fromJson(json, path);
  }

  /// The absolute canonical Resource URL.
  String get id;

  /// The declared Type ID.
  String get type;

  /// The current opaque revision.
  Revision get revision;

  /// The version's carried attribution, when one was recorded.
  Attribution? get attribution;

  /// The complete authored `properties` document.
  JsonObject get properties;

  /// The History capability's change context, carried verbatim when served.
  JsonObject? get changeContext;

  /// Which kind of Resource this is.
  ResourceKind get kind;

  /// This record's identity at its revision.
  ResourceIdentity get identity =>
      ResourceIdentity(id: id, type: type, revision: revision);

  /// The wire form.
  JsonObject toJson();
}

/// A canonical Bead record.
final class BeadRecord extends ResourceRecord {
  /// A Bead record.
  BeadRecord({
    required this.id,
    required this.type,
    required this.revision,
    required JsonObject properties,
    this.attribution,
    Map<String, List<LinkRecord>>? ownedLinks,
    this.links,
    JsonObject? changeContext,
  }) : properties = freezeObject(properties),
       ownedLinks = ownedLinks == null
           ? null
           : Map.unmodifiable({
               for (final entry in ownedLinks.entries)
                 entry.key: List<LinkRecord>.unmodifiable(entry.value),
             }),
       changeContext = changeContext == null
           ? null
           : freezeObject(changeContext),
       super._();

  /// Decodes a Bead record.
  factory BeadRecord.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return BeadRecord(
      id: reader.string('id'),
      type: reader.string('type'),
      revision: reader.decode('revision', Revision.fromJson),
      attribution: reader.optionalDecode('attribution', Attribution.fromJson),
      properties: reader.object('properties'),
      links: reader.optionalDecode(
        'links',
        (value, path) => Page.fromJson(value, path, LinkRecord.fromJson),
      ),
      ownedLinks: reader.optionalDecode('ownedLinks', _decodeOwnedLinks),
      changeContext: reader.optionalObject('changeContext'),
    );
  }

  @override
  final String id;

  @override
  final String type;

  @override
  final Revision revision;

  @override
  final Attribution? attribution;

  @override
  final JsonObject properties;

  /// The owned Links inlined in this record, keyed by Link Type URL; present
  /// exactly when the Bead's Type owns outgoing Link Types.
  final Map<String, List<LinkRecord>>? ownedLinks;

  /// The first page of incident Links, present only on an `include=links`
  /// read.
  final Page<LinkRecord>? links;

  @override
  final JsonObject? changeContext;

  @override
  ResourceKind get kind => ResourceKind.bead;

  @override
  JsonObject toJson() {
    final json = <String, Object?>{
      'id': id,
      'type': type,
      'revision': revision.toJson(),
    };
    putIfPresent(json, 'attribution', attribution?.toJson());
    json['properties'] = properties;
    putIfPresent(json, 'links', links?.toJson((link) => link.toJson()));
    putIfPresent(json, 'ownedLinks', switch (ownedLinks) {
      null => null,
      final owned => {
        for (final entry in owned.entries)
          entry.key: [for (final link in entry.value) link.toJson()],
      },
    });
    putIfPresent(json, 'changeContext', changeContext);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is BeadRecord &&
      other.id == id &&
      other.type == type &&
      other.revision == revision &&
      other.attribution == attribution &&
      other.links == links &&
      jsonEquality.equals(other.properties, properties) &&
      _ownedEquality.equals(other.ownedLinks, ownedLinks) &&
      jsonEquality.equals(other.changeContext, changeContext);

  @override
  int get hashCode => Object.hash(
    id,
    type,
    revision,
    attribution,
    links,
    jsonEquality.hash(properties),
    _ownedEquality.hash(ownedLinks),
    jsonEquality.hash(changeContext),
  );

  @override
  String toString() => 'BeadRecord($id@$revision)';
}

/// A canonical Link record.
final class LinkRecord extends ResourceRecord {
  /// A Link record.
  LinkRecord({
    required this.id,
    required this.type,
    required this.revision,
    required this.source,
    required this.target,
    required JsonObject properties,
    this.attribution,
    JsonObject? changeContext,
  }) : properties = freezeObject(properties),
       changeContext = changeContext == null
           ? null
           : freezeObject(changeContext),
       super._();

  /// Decodes a Link record.
  factory LinkRecord.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return LinkRecord(
      id: reader.string('id'),
      type: reader.string('type'),
      revision: reader.decode('revision', Revision.fromJson),
      attribution: reader.optionalDecode('attribution', Attribution.fromJson),
      source: reader.decode('source', Reference.fromJson),
      target: reader.decode('target', Reference.fromJson),
      properties: reader.object('properties'),
      changeContext: reader.optionalObject('changeContext'),
    );
  }

  @override
  final String id;

  @override
  final String type;

  @override
  final Revision revision;

  @override
  final Attribution? attribution;

  /// The source endpoint.
  final Reference source;

  /// The target endpoint.
  final Reference target;

  @override
  final JsonObject properties;

  @override
  final JsonObject? changeContext;

  @override
  ResourceKind get kind => ResourceKind.link;

  @override
  JsonObject toJson() {
    final json = <String, Object?>{
      'id': id,
      'type': type,
      'revision': revision.toJson(),
    };
    putIfPresent(json, 'attribution', attribution?.toJson());
    json['source'] = source.toJson();
    json['target'] = target.toJson();
    json['properties'] = properties;
    putIfPresent(json, 'changeContext', changeContext);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is LinkRecord &&
      other.id == id &&
      other.type == type &&
      other.revision == revision &&
      other.attribution == attribution &&
      other.source == source &&
      other.target == target &&
      jsonEquality.equals(other.properties, properties) &&
      jsonEquality.equals(other.changeContext, changeContext);

  @override
  int get hashCode => Object.hash(
    id,
    type,
    revision,
    attribution,
    source,
    target,
    jsonEquality.hash(properties),
    jsonEquality.hash(changeContext),
  );

  @override
  String toString() => 'LinkRecord($id@$revision)';
}

const MapEquality<String, List<LinkRecord>> _ownedEquality = MapEquality(
  values: ListEquality<LinkRecord>(),
);

Map<String, List<LinkRecord>> _decodeOwnedLinks(Object? json, String path) {
  final reader = JsonReader.of(json, path);
  return {
    for (final key in reader.keys) key: reader.list(key, LinkRecord.fromJson),
  };
}
