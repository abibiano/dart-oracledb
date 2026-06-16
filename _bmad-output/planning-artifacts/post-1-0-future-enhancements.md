# Post-1.0 Future Enhancement Candidates

**Date:** 2026-06-11
**Status:** Planning note for later epic definition
**Scope:** Candidate epics to consider after Epic 4 (advanced data types) and Epic 5 (connection pooling) are complete.

## Recommendation

Create a later post-1.0 enhancement epic around **streaming and incremental fetch APIs**, and a separate compatibility epic around **database character set conversion for non-AL32UTF8 Oracle databases**. Both are supported concepts in the node-oracledb reference project, but they should not be mixed into Epic 4 or Epic 5 because they change core result and wire-encoding behavior.

## Candidate Epic 6: Streaming and Incremental Result Consumption

### Goal

Let applications process large query outputs without materializing every row in memory and without relying on the current single `execute()` safety cap.

### Reference Support

- node-oracledb exposes `connection.queryStream()`, returning a readable stream for queries. Rows arrive as data events, metadata arrives separately, and callers can destroy the stream early. Evidence: `reference/node-oracledb/doc/src/api_manual/connection.rst:2265`.
- node-oracledb exposes `ResultSet`, which fetches rows one at a time or in groups, should be used when row counts are unpredictable, and can be converted to a stream. Evidence: `reference/node-oracledb/doc/src/api_manual/resultset.rst:7`, `reference/node-oracledb/doc/src/api_manual/resultset.rst:139`.
- node-oracledb recommends ResultSet or query streaming when query row counts are big or unpredictable to avoid memory limits and truncation. Evidence: `reference/node-oracledb/doc/src/api_manual/oracledb.rst:1293`.
- This package currently documents very large result sets as bounded by a 1,000 fetch round-trip safety cap. Evidence: `README.md:316`.

### Proposed Package Shape

- Add `OracleResultSet` as a closeable cursor-backed result object.
- Add `connection.queryStream(sql, [bindValues], {fetchSize}) -> Stream<OracleRow>` or an equivalent `executeStream()` API.
- Add `connection.execute(..., options: OracleExecuteOptions(resultSet: true))` only if it fits the existing API style after Epic 5.
- Support explicit cancellation and cleanup so early stream cancellation closes the server cursor.
- Preserve one in-flight operation per connection: an active result stream owns the connection until closed or fully drained.

### Acceptance Themes

- Streams rows incrementally across multiple fetch rounds.
- Does not materialize all rows before yielding the first row.
- Exposes metadata before or with the first row.
- Handles early cancellation by closing the server cursor and leaving the connection reusable.
- Protects statement cache behavior when streamed cursors are open.
- Passes integration tests on Oracle 23ai and Oracle 21c.

## Candidate Epic 7: Non-AL32UTF8 Database Character Set Compatibility

### Goal

Support Oracle databases whose database character set is not AL32UTF8, while keeping Dart strings as Unicode and the client-side wire encoding aligned with the thin reference behavior.

### Reference Support

- node-oracledb docs state all database characters are supported. In Thin mode, the database server performs the required conversion, while node-oracledb uses AL32UTF8 for all character data. Evidence: `reference/node-oracledb/doc/src/user_guide/globalization.rst:15`, `reference/node-oracledb/doc/src/user_guide/globalization.rst:54`.
- node-oracledb Thin advertises client character set support as UTF-8, not arbitrary client encodings. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:185`.
- node-oracledb ignores any character set component in `NLS_LANG`; this is not a client encoding switch. Evidence: `reference/node-oracledb/doc/src/user_guide/globalization.rst:209`.
- This package currently assumes UTF-8 and warns that non-UTF-8 database character sets may decode incorrectly. Evidence: `README.md:310`.
- Current Dart protocol buffers directly encode and decode strings as UTF-8. Evidence: `lib/src/protocol/buffer.dart:105`, `lib/src/protocol/buffer.dart:326`.
- Current fast auth data-types negotiation writes UTF-8 charset id 873, matching the node-oracledb thin data-types message. Evidence: `lib/src/protocol/messages/fast_auth_message.dart:127`, `reference/node-oracledb/lib/thin/protocol/messages/dataType.js:57`.

### Proposed Package Shape

- Do not expose arbitrary Dart-side text encodings as a first version.
- Instead, validate and implement the node-oracledb Thin model: negotiate UTF-8 client character data and rely on Oracle server conversion for database character sets.
- Add startup capability detection for server charset and national charset.
- Add integration coverage against a non-AL32UTF8 database image or fixture if one can be made reliable in CI.
- Add NCHAR/NVARCHAR2/NCLOB behavior only when the database national character set is compatible. node-oracledb Thin supports AL16UTF16 national character set and does not support UTF8 national character set. Evidence: `reference/node-oracledb/doc/src/user_guide/globalization.rst:36`.

### Acceptance Themes

- VARCHAR2/CHAR/CLOB round-trip correctly against at least one non-AL32UTF8 database character set.
- Bind values are encoded in the negotiated client character set expected by the server.
- Metadata exposes enough charset/form information to diagnose unsupported national character set cases.
- Unsupported database or national charset configurations fail loud with `OracleException`, not silent mojibake.
- README replaces the current limitation with the tested support matrix and known exclusions.

## Other Useful Post-1.0 Candidates From the Reference

### High Value

1. **REF CURSOR and implicit results.** node-oracledb Thin supports REF CURSORs, nested cursors, and implicit result sets. These build naturally on `OracleResultSet` and streaming. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:263`, `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:272`, `reference/node-oracledb/doc/src/user_guide/plsql_execution.rst:342`.
2. **Bulk DML / `executeMany()`.** node-oracledb Thin supports array DML binding for bulk DML and PL/SQL. This is likely high-impact for server and mobile apps that insert or update many rows. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:176`, `reference/node-oracledb/doc/src/api_manual/connection.rst:1629`.
3. **Temporary LOBs and public LOB streaming.** node-oracledb supports temporary LOB creation and LOB streaming. This is a logical follow-on after Epic 4 basic CLOB/BLOB value support. Evidence: `reference/node-oracledb/doc/src/api_manual/connection.rst:892`, `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:278`.
4. **JSON and OSON parity.** The existing PRD already includes JSON. node-oracledb Thin supports Oracle 12c JSON-as-BLOB and Oracle 21c JSON type. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:296`, `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:299`.

### Medium Value

1. **INTERVAL DAY TO SECOND and INTERVAL YEAR TO MONTH.** node-oracledb supports both. Useful for schema completeness, but less urgent than streaming, charset, bulk DML, and REF CURSORs. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:287`.
2. **ROWID / UROWID.** node-oracledb supports these types. Useful for advanced DML and change-tracking workflows. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:778`.
3. **TIMESTAMP WITH TIME ZONE region-name compatibility.** The package already supports offset-based TSTZ values as UTC `DateTime` by default, and as opt-in `OracleTimestampTz` preserving the original offset. The remaining useful enhancement is support for region-id TSTZ values such as `Europe/Madrid`, or at minimum default-mode decode of their UTC instant plus clear preservation limits. Current README documents region-id zones as rejected; Story 7.9 notes that after the TSTZ UTC-fields fix, region-id values may be decodable to a correct UTC instant but were kept out of scope. Evidence: `README.md:23`, `README.md:334`, `_bmad-output/implementation-artifacts/7-9-api-surface-error-handling-ci-release-tooling.md:114`, `_bmad-output/implementation-artifacts/7-9-api-surface-error-handling-ci-release-tooling.md:223`.
4. **Temporal fetch formatting / fetch-as-string hooks.** node-oracledb supports fetching dates/timestamps as strings and using fetch type handlers for custom date/time representation. This would help callers that need exact Oracle textual formatting, region names, or application-specific display without forcing every TSTZ into a Dart object. Evidence: `reference/node-oracledb/doc/src/user_guide/sql_execution.rst:1015`, `reference/node-oracledb/doc/src/user_guide/sql_execution.rst:1032`.
5. **VECTOR.** node-oracledb supports Oracle AI Database VECTOR. Useful if the package wants 23ai AI workload parity after core database-driver maturity. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:323`, `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:814`.
6. **AQ / TxEventQ.** node-oracledb Thin supports AQ/TxEventQ, but this is a large surface area with queue administration, payload types, transaction semantics, and notifications. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:212`.

### Defer or Treat as Out of Scope for Pure Thin Mode

1. **SODA.** Current node-oracledb API docs state SODA is Thick mode only in this release. Do not prioritize for this pure Dart thin driver unless a separate SQL/PLSQL-backed design is researched. Evidence: `reference/node-oracledb/doc/src/api_manual/sodadb.rst:14`.
2. **CQN / subscriptions.** node-oracledb Thin support appears limited or absent in the feature matrix, and it brings long-lived notification transport concerns. Defer until the core connection, pool, and streaming lifecycle is mature. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:209`.
3. **External/Kerberos authentication and native network encryption.** These are Thick-mode capabilities in the reference matrix and conflict with the pure Dart/no Oracle Client direction. Evidence: `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:71`, `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:98`, `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:104`.

## Suggested Order After Epic 4 and Epic 5

1. Streaming and ResultSet API.
2. REF CURSOR and implicit results, built on ResultSet.
3. Non-AL32UTF8 database charset compatibility.
4. Bulk DML / `executeMany()`.
5. Public LOB streaming and temporary LOBs.
6. JSON/OSON parity.
7. Temporal compatibility: TSTZ region names and optional fetch-as-string/custom fetch hooks.
8. Medium-value type completeness: INTERVAL, ROWID/UROWID, VECTOR.
9. AQ/TxEventQ only if there is a concrete user need.
