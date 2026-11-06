# Changelog

## 0.1.0-dev.1

- `GcApi` over an injected `http.Client`: the supervisor's health and cities, and through
  `GcCity` a city's status, its event log by page, and its live event stream with
  reconnection after the last event delivered. Failures are `GcProblemException`,
  `GcHttpException` and `GcProtocolException`. Read-only; runs on the web.
