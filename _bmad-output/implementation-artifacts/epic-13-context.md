# Epic 13 Context: JSON / OSON Parity

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Deliver full JSON support across the Oracle versions the thin driver targets, reaching node-oracledb thin-mode parity: the Oracle 21c+ native JSON type (binary OSON encoding) and the older Oracle 12c pattern of JSON stored in a BLOB column. The work extends the JSON support shipped in 1.0, which already maps JSON to Dart `Map`/`List`. Users get one consistent JSON experience regardless of how the database stores JSON, so applications don't have to special-case server versions or hand-decode JSON bytes.

## Stories

- Story 13.1: Oracle 21c native JSON (OSON) codec
- Story 13.2: Oracle 12c JSON-as-BLOB compatibility path
- Story 13.3: Bind & fetch JSON (Dart map/list mapping)
- Story 13.4: Dual-env integration tests (23ai + 21c)

## Requirements & Constraints

- Oracle JSON values map to Dart `Map`/`List` (plus JSON scalars) on fetch, and Dart `Map`/`List` values bind as JSON. Keep this contract for every storage form.
- JSON stored as BLOB (12c style, `IS JSON` constraint) must be readable and writable through the same Dart mapping as native JSON. It must not come back as raw bytes when the driver can tell the column holds JSON.
- Fail loud, never silently: an unsupported OSON node or JSON shape raises `OracleException`. It never returns `null` or corrupted data.
- Preserve node-oracledb thin parity wherever the reference documents the behavior.
- Out of scope: SODA (thick-mode only in the reference).
- Definition of Done for every story:
  - `dart analyze` reports zero warnings.
  - Integration tests use `test_helper.dart`, with no hardcoded connection parameters.
  - Integration tests pass on both Oracle 23ai (FAST_AUTH, port 1521 / FREEPDB1) and Oracle 21c (classical AUTH, port 1522 / XEPDB1). Passing on 23ai alone does not count.

## Technical Decisions

- **Starting point:** native JSON (OSON, oraType 119) encode/decode already works end to end. The OSON codec lives in `lib/src/protocol/oson.dart`, and the execute-message decode path dispatches to it. Story 13.1 is mainly hardening, completeness and parity verification of that codec, not a from-scratch build.
- **Main gap:** there is no 12c JSON-as-BLOB path and no fallback. Planned approach:
  - Detect JSON stored as BLOB from `IS JSON` / column metadata.
  - Route the bytes through the OSON codec or a text-JSON decode, depending on the server version and what the bytes actually contain.
  - Expect changes in `oson.dart` and the transport layer (`transport.dart`), since BLOB contents are read through the existing LOB machinery.
- **Embedded OSON scalars:** Story 13.1 decodes date/timestamp, timestamp with time zone, binary float/double, and binary nodes. The decoder still fails loud on interval, JsonId, and extended VECTOR nodes. Interval and VECTOR codecs arrive with Epics 14/15; keep fail-loud for unsupported kinds.
- **Scalar-codec recipe:** if any new scalar type is added, follow the project's fixed recipe:
  1. Constant in `constants.dart`.
  2. Encode/decode in `data_types.dart`.
  3. Bind-encode case and buffer sizes in `execute_message.dart`.
  4. Decode-by-oraType case.
  5. `inferOraTypeForValue`.
  6. Optional wrapper type.
  7. Unit tests plus dual-env integration tests.
- **Fail-loud direction:** across post-1.0 work, decode is moving toward this rule: a known type decodes, a recognized but unsupported type throws `OracleException`, and nothing returns a silent `null`. OSON's fail-loud behavior is one instance of that rule, so don't weaken it.
- **Encoding:** keep explicit encodings. Primary character data on the wire stays UTF-8 (AL32UTF8), consistent with the Epic 10 charset model.
- **Test layout:** tests mirror `lib/src/`. Unit tests use the `_test.dart` suffix. New integration suites go under `test/integration/json_*`.

## Cross-Story Dependencies

- 13.3 (bind/fetch mapping) depends on the codec work in 13.1 and the BLOB routing in 13.2. 13.4 validates all three on both databases.
- This epic builds on the 1.0 JSON work (Story 4.4) and the existing LOB value support. The JSON-as-BLOB path should reuse the LOB read/write infrastructure, including Epic 12's public LOB/streaming work, instead of duplicating it.
- Wider OSON embedded-scalar support depends on the Epic 14 (temporal) and Epic 15 (INTERVAL/VECTOR) codecs. Anything not yet available stays fail-loud.
