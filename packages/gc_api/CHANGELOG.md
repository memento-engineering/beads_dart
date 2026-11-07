# Changelog

## Unreleased

- GcCity reads a city's sessions by page (sessions, filtered by cursor, limit, state and
  template), one session (session), the sessions waiting on a human (pending), and one
  session's pending interaction (sessionPending). All are GETs.

## 0.1.0-dev.1

- `GcApi` over an injected `http.Client`: the supervisor's health and cities, and through
  `GcCity` a city's status, its event log by page, and its live event stream with
  reconnection after the last event delivered. Failures are `GcProblemException`,
  `GcHttpException` and `GcProtocolException`. Read-only; runs on the web.
