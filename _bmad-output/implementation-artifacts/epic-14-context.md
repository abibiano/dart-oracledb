# Epic 14 Context: Temporal Compatibility & Fetch Type Handlers

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Close the remaining temporal gaps in the pure-Dart thin-mode Oracle driver and let callers control how fetched values are represented. Region-id TIMESTAMP WITH TIME ZONE values (e.g. `Europe/Madrid`), currently rejected, must decode to a correct UTC instant. Callers who need exact Oracle text, region names, or application-specific display must be able to get it through fetch-as-string and per-column fetch type handlers, without every TSTZ being forced into a Dart object. This is a post-1.0 compatibility epic that follows the reference node-oracledb behavior.

## Stories

- Story 14.1: TSTZ region-name decode
- Story 14.2: Region-name preservation
- Story 14.3: Fetch-as-string
- Story 14.4: Fetch type-handler hooks
- Story 14.5: Dual-env integration tests

## Requirements & Constraints

- Existing behavior is the baseline and must not regress. Offset-based TSTZ decodes to a UTC `DateTime` by default. An opt-in mode returns `OracleTimestampTz`, which preserves the original offset. DATE and TIMESTAMP map to `DateTime`, TIMESTAMP with precision.
- Region-id TSTZ is currently documented as rejected. The minimum deliverable is default-mode decode to the correct UTC instant. Whether region-name preservation is possible is optional, and any limits must be clearly documented (README and docs updated, since the README currently says region-ids are rejected).
- Story 7.9 noted that after the TSTZ UTC-fields fix, region-id values are probably decodable to a correct UTC instant but were deliberately left out of scope.
- Fetch-as-string must cover dates and timestamps, to give exact Oracle textual formatting.
- A fetch type handler is a custom per-column conversion. Parity target: the reference handler picks the type and a converter.
- Behavior must be fail-loud. Never return silent `null` or wrong values for undecodable input.
- Every story inherits the mandatory dual-environment validation rule. Unit tests plus integration tests must pass on Oracle 23ai (localhost:1521, FREEPDB1, Docker Desktop) and Oracle 21c (localhost:1522, XEPDB1, Colima). One environment is never enough. Story 14.5 is the dedicated dual-env story.
- Out of scope for the driver: anything requiring the Oracle Client or thick mode.

## Technical Decisions

- Region-id TSTZ is the `byte11 & 0x80` form in the TSTZ wire value. Decode it to a UTC instant. It lives in the temporal decode in `lib/src/protocol/data_types.dart` and the `OracleTimestampTz` wrapper in `oracle_timestamp_tz.dart`.
- The decode path is currently a pure `switch(oraType)` with no hook infrastructure. The fetch type handler is the one structural change.
  - Thread an optional per-column hook `(value, ColumnMetadata) -> Object?` through `_decodeValueByOraType`, then `_decodeColumnValue`, then `ExecuteResponse`, then transport decode.
  - Carry it on the request/decode context so it survives multi-round FETCH, not just the first response.
  - Expose it as a `fetchTypeHandler` option on the connection (`connection.dart`), with the hook wiring in `execute_message.dart`.
  - Fetch-as-string is a convenience built on the same hook, not a separate mechanism.
- Follow the scalar-type codec recipe where a new codec or wrapper is added: constant, then encode/decode in `data_types.dart`, then bind/define sizes in `execute_message.dart`, then the decode-by-type case and type inference, then an optional Dart wrapper, then unit and dual-env tests.
- Convention: fail loud with `OracleException` for recognized-but-unsupported input, in line with the project-wide fail-loud rule.

## Cross-Story Dependencies

- No dependency on other epics. This epic extends the Epic 4 and Story 7.9 temporal codecs.
- 14.2 builds on 14.1 (region decode comes first, then optional name preservation).
- 14.3 builds on the hook infrastructure from 14.4. Design the hook plumbing once and implement fetch-as-string on top of it, whichever story lands first.
- 14.5 validates 14.1 to 14.4 on 23ai and 21c.
- Epic 13 (OSON embedded scalar coverage) may optionally reuse the temporal codecs. Epic 15 (INTERVAL, ROWID, VECTOR) shares the same codec and decode-path files, so avoid conflicting edits to the decode switch.
