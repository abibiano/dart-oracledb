# Epic 15 Context: Extended Data Type Completeness

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Round out the pure-Dart thin-mode Oracle driver's type coverage so that schemas using INTERVAL DAY TO SECOND, INTERVAL YEAR TO MONTH, ROWID/UROWID and the Oracle 23ai VECTOR type can be queried and bound correctly. Today these columns are silently skipped or decoded as `null`, which corrupts results without any error. This is a medium-value, post-1.0 parity epic that follows node-oracledb thin behavior. It ends by flipping the decoder's catch-all from silent `null` to fail-loud, so that any column type the driver still does not know raises an error.

## Stories

- Story 15.1: INTERVAL DAY TO SECOND
- Story 15.2: INTERVAL YEAR TO MONTH
- Story 15.3: ROWID / UROWID
- Story 15.4: VECTOR (Oracle 23ai)
- Story 15.5: Dual-env integration tests

## Requirements & Constraints

- Parity target is node-oracledb thin support for INTERVAL DS/YM, ROWID/UROWID and VECTOR. Where the reference has defined behavior, match it.
- Fail loud. Never return a silent `null` or a wrong value. The rule is: a known type decodes, a recognized-but-unsupported type raises `OracleException`, and nothing is silently swallowed. Once the known types land, the decode-by-type `default` (which currently consumes the bytes and returns `null`) must throw `OracleException` instead.
- VECTOR only exists on Oracle 23ai. Tests for the other types must pass on both databases. VECTOR tests must be explicitly gated to 23ai, with the gap logged or documented, not silently skipped.
- Definition of Done for every story:
  - `dart analyze` passes with zero warnings.
  - Integration tests use `test_helper.dart` (no hardcoded connection params).
  - Tests pass on Oracle 23ai (localhost:1521, FREEPDB1, Docker Desktop, FAST_AUTH) and on Oracle 21c (localhost:1522, XEPDB1, Colima, classical AUTH). One environment is never enough. Story 15.5 is the dedicated dual-env story.
- Out of scope: anything needing the Oracle Client or thick mode.
- The README currently lists INTERVAL, ROWID/UROWID and VECTOR completeness as a roadmap item. Update the README/docs support matrix as the types ship.

## Technical Decisions

- Every type follows the fixed scalar-codec recipe:
  1. Add the constant in `constants.dart`.
  2. Add encode/decode in `data_types.dart`.
  3. In `execute_message.dart`, add the bind-encode case and the define/bind buffer sizes.
  4. Add the `_decodeValueByOraType` case.
  5. Add `inferOraTypeForValue` support.
  6. Add the Dart wrapper type, if one is needed.
  7. Add unit tests and dual-env integration tests.
- Constants: ROWID (11) and UROWID (104) constants already exist but have no decode case. INTERVAL DS/YM and VECTOR need new constants (`oraTypeInterval*`, `oraTypeVector`). Take the wire ids from the node-oracledb reference.
- Dart representations:
  - Intervals: wrapper types in a new `lib/src/oracle_interval.dart` (`OracleIntervalYM` / `OracleIntervalDS`), modelled on `OracleTimestampTz`.
  - ROWID/UROWID: `String`.
  - VECTOR: `List<double>` or a wrapper. Settle this at story time against reference behavior.
- VECTOR column metadata: the 23.4 vector fields in column info are already read only when the server negotiates field version >= 24. Reuse that gating; don't add another one.
- New integration suites go under `test/integration/extended_types_*`.
- Epic 14 added an optional per-column fetch type-handler hook to the decode path. New codecs plug into the same `_decodeValueByOraType` switch, so the handler and fetch-as-string must keep working for the new types.

## Cross-Story Dependencies

- This epic depends on no other epic. It extends the Epic 4 scalar codecs and shares `data_types.dart` / `execute_message.dart` with Epic 14's temporal and hook changes.
- 15.1 and 15.2 share the interval wrapper file. Design `oracle_interval.dart` once so both fit.
- Flipping the `default` to fail-loud should land only after 15.1 to 15.4 cover their types. Otherwise the flip breaks queries that currently "work" by returning `null`.
- 15.5 validates 15.1 to 15.4 on 23ai and 21c, with VECTOR on 23ai only.
- Epic 13 follow-up: the OSON decoder currently fail-louds on embedded INTERVAL YM/DS and VECTOR nodes. Once these codecs and wrappers exist, OSON can optionally reuse them. That work is not part of this epic unless a story pulls it in.
