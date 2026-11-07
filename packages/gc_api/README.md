# gc_api

A client for the Gas City supervisor's HTTP API. It runs on every platform, the web included,
and takes the `http.Client` it uses, so a Flutter app passes its own.

It reads Gas City's own state. Beads are not read here: a client reaches beads over BDP, through
`package:bdp/client.dart`, so the same bead code serves a Gas City store and the grid's Scopes.

```dart
final api = GcApi(httpClient: http.Client()); // http://127.0.0.1:8372
final health = await api.health();
final city = api.city('houston');
final status = await city.status();
final page = await city.events(limit: 50);       // newest first
final older = await city.events(cursor: page.nextCursor);
final live = city.follow(afterSeq: page.events.first.seq).listen(print);
final waiting = await city.pending();
```

## What it covers

| Call | Route |
| --- | --- |
| `GcApi.health` | `GET /health` |
| `GcApi.cities` | `GET /v0/cities` |
| `GcCity.status` | `GET /v0/city/{name}/status` |
| `GcCity.events` | `GET /v0/city/{name}/events` |
| `GcCity.follow` | `GET /v0/city/{name}/events/stream` |
| `GcCity.sessions` | `GET /v0/city/{name}/sessions` |
| `GcCity.session` | `GET /v0/city/{name}/session/{id}` |
| `GcCity.pending` | `GET /v0/city/{name}/pending` |
| `GcCity.sessionPending` | `GET /v0/city/{name}/session/{id}/pending` |

Everything here is a GET, so a supervisor bound beyond loopback without `allow_mutations`
serves all of it. Mutations come with the routes that need them, each carrying `X-GC-Request`.

## The event stream

`follow` delivers a city's events oldest first and reconnects by itself. It starts after
`afterSeq`, replaying what the log still holds, or at the head without it. A dropped connection,
a timeout, a rate limit or a server error reconnects after the last event delivered, waiting
`reconnectDelay` or the server's SSE `retry`; no event is delivered twice or skipped. A 4xx, a
Problem Details refusal or a body that is not the API's ends the stream with the error.
Cancelling the subscription aborts the request.

## Failures

- A Problem Details body (`application/problem+json`) is a `GcProblemException` carrying a
  `GcProblem`. Every member of it is optional: a refusal made before routing carries only
  `title`, `status` and `detail`. `GcProblem.readOnly` says the server refused a mutation
  because it is read-only.
- Any other failing status is a `GcHttpException`, `transient` for 408, 429 and 5xx.
- A body that is not JSON, or not the shape the API describes, is a `GcProtocolException`
  naming the field.

## Tests

`test/spec_test.dart` holds the client to the supervisor's own OpenAPI description, vendored as
`test/fixtures/openapi.json`. Every operation and parameter the client sends exists, every
fixture has the shape of its response, and each fixture is read again without each optional
member in turn, so the client never requires a field the description makes optional.
`test/web_test.dart` compiles a program importing the package with `dart compile js`.
