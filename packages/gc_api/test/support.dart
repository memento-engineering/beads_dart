import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The fixture directory: `dart test` runs in the package.
final fixtures = '${Directory.current.path}/test/fixtures';

/// The text of the fixture [name].
String fixture(String name) => File('$fixtures/$name').readAsStringSync();

/// The fixture [name] decoded as JSON.
Object? fixtureJson(String name) => jsonDecode(fixture(name));

/// The fixture [name] as a response of [status].
http.Response jsonResponse(
  String name, {
  int status = 200,
  String contentType = 'application/json',
}) => http.Response(
  fixture(name),
  status,
  headers: {'content-type': contentType},
);
