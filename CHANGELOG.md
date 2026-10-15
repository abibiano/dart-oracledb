# Changelog

## Unreleased

### Features

- **Region-id `TIMESTAMP WITH TIME ZONE` values now decode** instead of
  failing the whole fetch with `oraUnsupportedType`. A value stored with a
  named region (e.g. `Europe/Madrid`, `US/Pacific`) decodes to its correct
  UTC instant — the same instant as the server's `SYS_EXTRACT_UTC`,
  including DST-transition values and fractional seconds — in columns,
  PL/SQL OUT binds, and native JSON members: a UTC `DateTime` by default, or
  an `OracleTimestampTz` on a `preserveTimestampTimeZone: true` connection
  (and always inside JSON). Validated against Oracle 23ai and Oracle 21c,
  across every region name each server knows.
- **Region names are recoverable (opt-in).** An `OracleTimestampTz` decoded
  from a region-id value (on a `preserveTimestampTimeZone: true` connection,
  in PL/SQL OUT binds, and always inside JSON) now carries the server's
  numeric region id in the new `regionId` field (`null` for numeric-offset
  values), and the new `OracleConnection.timeZoneRegionName(value)` resolves
  it to the region name as Oracle's `TZR` element renders it (e.g.
  `'EUROPE/MADRID'`). Names come from the connected database's own
  `V$TIMEZONE_NAMES` — no region table is bundled — read in one query on the
  first lookup and cached for the connection's lifetime. A value without a
  region id resolves to `null` with no query; an id absent from the server's
  table throws `OracleException` (ORA-01882); an unreadable view raises the
  server error, naming `V$TIMEZONE_NAMES`. `OracleTimestampTz` gains an
  optional `regionId` (0..8191, `ArgumentError` otherwise) on all three
  constructors, and its `==`, `hashCode`, `compareTo` and `toString` include
  it. Default-mode decoding (a UTC `DateTime`) is unchanged. Validated
  against Oracle 23ai and Oracle 21c, resolving every region name each server
  knows.
- **Limits:** the region's offset is never computed (no time-zone rules are
  bundled): an `OracleTimestampTz` decoded from a region-id value reports
  `+00:00` (the UTC-normalized instant, not the region's offset). Binding
  stays offset-only — `regionId` is ignored, so binding such a value back
  stores the instant at `+00:00` without the region. Names follow the
  connected server's time-zone file, so resolve a value against the database
  it came from; the lookup needs read access to `V$TIMEZONE_NAMES` (granted
  to `PUBLIC` by default), and the first lookup on a connection cannot run
  while an `OracleResultSet` or another operation holds it. Inside nested
  JSON constructors the server may not keep the region (Oracle 23ai may
  resolve it to its offset, 21c may store `+00:00`); such members decode as
  ordinary offset values without a `regionId`.
- **Behavior change:** queries over region-id `TIMESTAMP WITH TIME ZONE` data
  that previously threw `OracleException` (`oraUnsupportedType`) now return
  rows. BCE values and malformed numeric zone offsets still fail loudly
  (unchanged).
- **Fetch dates and timestamps as strings (opt-in).** The new
  `OracleExecuteOptions.fetchAsString` (a `Set<OracleDbType>`, default empty)
  returns the selected column types as `String` (node-oracledb
  `fetchAsString` parity for dates and timestamps): `OracleDbType.date`
  converts `DATE`; `OracleDbType.timestamp` converts `TIMESTAMP` and
  `TIMESTAMP WITH LOCAL TIME ZONE`; `OracleDbType.timestampTz` converts
  `TIMESTAMP WITH TIME ZONE`. It works on the eager path (with or without
  `maxRows`) and on every batch of a `resultSet: true` result set, and a
  cached statement re-executed with and without the option returns each
  call's own representation. SQL `NULL` stays `null`. Any other
  `OracleDbType` throws `ArgumentError` before any round trip. Validated
  against Oracle 23ai and Oracle 21c.
- **Limits:** as in node-oracledb thin mode, the column is still fetched in
  binary (Oracle ignores a text define for these types) and the text is the
  decoded value's own `toString()` — e.g. `2024-03-05 00:00:00.000`, a UTC
  `...Z` instant for `TIMESTAMP WITH TIME ZONE`, or
  `OracleTimestampTz(... regionId=...)` on a `preserveTimestampTimeZone:
  true` connection. It does not follow the session's NLS formats, keeps
  microsecond precision only and never shows a region name; select
  `TO_CHAR(col, 'format')` for Oracle's exact text. Only the top-level
  query's rows convert: REF CURSOR OUT bind, nested `CURSOR(...)` and PL/SQL
  implicit-result rows keep their native types, and `executeStream()` /
  `queryStream()` take no options. Column metadata still reports the
  database type.
- **Per-column fetch type handlers (opt-in).** The new
  `OracleExecuteOptions.fetchTypeHandler` (node-oracledb `fetchTypeHandler`
  parity for its converter half) is called once per result column, in
  column order, with the column's `ColumnMetadata` and the list of all
  result columns, and returns a converter for that column or `null` to keep
  the default. The converter maps every non-NULL value of its column — as
  decoded: `int`/`double`, `String`, `Uint8List`, `DateTime`,
  `OracleTimestampTz`, JSON `Map`/`List`, a nested cursor's
  `List<OracleRow>`, or an `OracleLob` under `fetchLobs: true` — to any
  `Object?` (e.g. a NUMBER as `String`, a custom date format). It applies on
  the eager path (with or without `maxRows`) and to every batch of a
  `resultSet: true` result set, exactly once per cell (Oracle's
  duplicate-column copies across fetch rounds are converted from the decoded
  value, never re-converted). SQL `NULL` stays `null` without calling the
  converter. A converter wins over `fetchAsString` for its column;
  `fetchAsString` still applies to columns the handler returned `null` for.
  The handler runs per call, so a cached statement re-executed with a
  different handler (or none) returns each call's own representation. An
  exception thrown by the handler or a converter propagates unchanged (not
  wrapped in `OracleException`), no rows of the failed call or batch are
  returned, and the connection stays usable. New public typedefs
  `OracleFetchTypeHandler` and `OracleFetchConverter`. Option omitted (or a
  handler that always returns `null`): behavior unchanged. Validated against
  Oracle 23ai and Oracle 21c.
- **Limits:** converter only — there is no node-oracledb `type`: every column
  is still fetched natively (no DEFINE, no SQL rewrite) and converted by the
  driver, synchronously (a returned `Future` is not awaited), so the result
  never follows NLS settings; use `TO_CHAR(...)` in SQL for Oracle's own
  text. Only the top-level query's rows are converted: REF CURSOR OUT bind,
  nested `CURSOR(...)` and PL/SQL implicit-result rows and OUT binds keep
  their default types and never reach the handler; there is no
  connection-level or global handler, and `executeMany()` /
  `executeStream()` / `queryStream()` do not take it. Under `fetchLobs:
  true` the converter receives the `OracleLob` handle, which stays the
  caller's to close (a result set's `close()` still reaps the handles of rows
  never retrieved). Column metadata still reports the database type.
- **`INTERVAL DAY TO SECOND` columns decode and bind.** They previously
  decoded silently to `null` and could not be bound. Columns, PL/SQL OUT
  binds, DML `RETURNING` values and REF CURSOR / nested `CURSOR()` /
  implicit-result rows now decode to the new `OracleIntervalDS` (node-oracledb
  `IntervalDS` parity: signed `days`, `hours`, `minutes`, `seconds` and
  `fseconds` in nanoseconds; `==`/`hashCode`, `toString()` as
  `OracleIntervalDS(+3 04:05:06.123456789)`, `toDuration()` / `OracleIntervalDS.fromDuration()`). An
  `OracleIntervalDS` or a Dart `Duration` (microsecond resolution) binds as
  an interval — inferred for IN binds and `executeMany()` rows, or declared
  with the new `OracleDbType.intervalDS` (no `maxSize`) for OUT / IN OUT and
  `OracleBindDef`. The constructor carries units like node-oracledb and
  throws `ArgumentError` outside `INTERVAL DAY(9) TO SECOND(9)` and — unlike
  node-oracledb — for components of mixed signs, which Oracle stores
  verbatim and then renders inconsistently. A malformed wire value fails
  with `OracleException` (`oraProtocolError`) instead of decoding.
  `fetchTypeHandler` converters receive the `OracleIntervalDS`. Validated
  against Oracle 23ai and Oracle 21c. `Duration` bind values, previously
  rejected as unsupported, now bind as intervals.
- **`INTERVAL YEAR TO MONTH` columns decode and bind.** They previously
  decoded silently to `null` and could not be bound. Columns, PL/SQL OUT
  binds, DML `RETURNING` values and REF CURSOR / nested `CURSOR()` /
  implicit-result rows now decode to the new `OracleIntervalYM`
  (node-oracledb `IntervalYM` parity: signed `years` and `months`;
  `==`/`hashCode`, `toString()` as `OracleIntervalYM(+3-05)`). An
  `OracleIntervalYM` binds as an interval — inferred for IN binds and
  `executeMany()` rows, or declared with the new `OracleDbType.intervalYM`
  (no `maxSize`) for OUT / IN OUT and `OracleBindDef`. No Dart-native type
  binds as one (a `Duration` stays INTERVAL DAY TO SECOND). The constructor
  carries every 12 months into a year like node-oracledb and throws
  `ArgumentError` outside `INTERVAL YEAR(9) TO MONTH` and — unlike
  node-oracledb — for years and months of opposite signs, which Oracle stores
  verbatim and then renders and compares inconsistently (measured on 23ai
  and 21c). A malformed wire value fails with `OracleException`
  (`oraProtocolError`) instead of decoding. `fetchTypeHandler` converters
  receive the `OracleIntervalYM`. Validated against Oracle 23ai and Oracle
  21c.
- **Limits (both interval types):** intervals inside native JSON and
  `fetchAsString` for intervals remain unsupported. Known issue (not
  interval-specific, pre-existing): on Oracle 21c a SQL `NULL` of any type
  in a REF CURSOR / nested `CURSOR()` / implicit-result row without a LOB or
  JSON column fails the call with ORA-01405, so NULL intervals are not supported inside cursors there
  (non-NULL values decode on both versions).

## 1.5.0

### Features

- **A plain `execute()` of an INSERT/UPDATE/DELETE with `RETURNING ... INTO`
  now accepts `OracleBind.out(...)` specs** for the INTO targets, on the same
  wire path as `executeMany()` (one iteration). Each OUT bind yields a `List`
  of the returned values, one per affected row (empty when no row matched).
  `OracleBind` specs on any other non-PL/SQL statement are still rejected.
  `MERGE ... RETURNING` works on Oracle 23ai only. The streamed-LOB insert
  idiom no longer needs a PL/SQL wrapper. Validated against Oracle 23ai and
  Oracle 21c.

- **Oracle-specific scalars inside native `JSON` values now decode** instead of
  failing the whole row. A JSON document (or scalar JSON value, e.g.
  `JSON_SCALAR(SYSDATE)`) that carries Oracle `DATE` / `TIMESTAMP` values
  decodes them to `DateTime` and `RAW` / binary to `Uint8List` (as the
  matching columns do), `TIMESTAMP WITH TIME ZONE` always to
  `OracleTimestampTz` regardless of `preserveTimestampTimeZone` (a column
  returns a UTC `DateTime` by default), and `BINARY_FLOAT` / `BINARY_DOUBLE`
  to `double` (NaN and ±Infinity included). BCE dates and region-name time
  zones still failed loudly in this release, as they did for columns
  (superseded: region-name zones now decode; see the newer entry above).
  Surrounding members and
  key order are unaffected. Validated against Oracle 23ai and Oracle 21c.
- **Behavior change:** documents that previously failed with
  `oraUnsupportedType` now return maps/lists containing `DateTime`,
  `OracleTimestampTz`, `Uint8List`, or NaN/±Infinity `double` members, so
  `jsonEncode()` on such a fetched document can throw
  `JsonUnsupportedObjectError`.
- **JSON binds now accept every value a JSON fetch returns**, so a fetched
  document binds back unchanged (DML, `executeMany()`, PL/SQL IN OUT) and
  round-trips as the same Dart types. Inside a `Map` / `List` bind (or as an
  explicitly JSON-typed scalar root), a `DateTime` travels as an OSON
  `TIMESTAMP` (7 bytes with no sub-second part, else 11; written from its
  wall-clock fields like a `DATE` / `TIMESTAMP` column bind), an
  `OracleTimestampTz` as `TIMESTAMP WITH TIME ZONE` (offset preserved), a
  `Uint8List` as binary (node-oracledb `oson.js` parity), and doubles outside
  Oracle `NUMBER`'s range (a non-zero magnitude below 1E-130, or 1E126 and
  up) as `BINARY_DOUBLE` — a Dart-driver extension: node-oracledb cannot bind
  those. NaN / ±Infinity travel as `BINARY_DOUBLE` too, but only on opt-in
  (see the JSON bind hardening entry under Fixes). Every other `num`,
  `0.0` / `-0.0` included, stays `NUMBER`, as before. A finite fetched
  `BINARY_FLOAT` /
  `BINARY_DOUBLE` within `NUMBER`'s range still re-binds as `NUMBER` (equal
  value). Validated against Oracle 23ai and Oracle 21c, which accept every
  node; a text `BLOB IS JSON` column stores such members as Oracle's JSON text
  (ISO-8601 / hex / `"Nan"` strings), an `IS JSON FORMAT OSON` column keeps
  them.
- **Scalar JSON roots can be bound through PL/SQL**, where the JSON type is
  declared explicitly — `OracleBind.inOut(value: 'x', type:
  OracleDbType.json, ...)` on an `IN OUT JSON` parameter, or `executeMany()`
  of a PL/SQL block with `OracleBindDef.input(type: OracleDbType.json)` in
  `bindDefs`: `String`, `num`, `bool`, `DateTime`, `OracleTimestampTz`, or
  `Uint8List`. Plain SQL DML cannot bind one — its binds take their type
  from the value, and type inference is unchanged: a bare `String` still
  binds as `VARCHAR2`, `Uint8List` as `RAW`, `DateTime` as `DATE`.
- **Behavior change:** invalid JSON bind values still fail loudly at the call
  site — `Set`, non-`String` keys, arbitrary objects, field names over 255
  UTF-8 bytes (previously caught only while encoding; 65535 on Oracle 23ai,
  see Fixes), and dates outside
  years 1–9999 — and an `execute()` `Map` / `List` bind is now validated
  while its binds are prepared, before any transport work. The
  `ArgumentError` no longer carries the bind value — no member values and
  no object keys; it names the offending member's path (list indices and
  1-based object member positions, e.g. `[member #2]`) and type — matching
  the other typed-bind errors.
- JSON values holding the remaining Oracle-specific scalars — `INTERVAL YEAR
  TO MONTH`, `INTERVAL DAY TO SECOND`, `JsonId`, VECTOR — still fail loudly
  with `OracleException` (`oraUnsupportedType`), whose message now names the
  kind and the supported scope.
- **JSON stored in a `BLOB` (the Oracle 12c `IS JSON` pattern) now decodes
  like native JSON.** A `BLOB` column with an `IS JSON` (or `IS JSON FORMAT
  OSON`) check constraint returns `Map<String, Object?>` / `List<Object?>` /
  a Dart scalar for eager `execute()`, `resultSet: true`,
  `queryStream()` / `executeStream()` and implicit result sets, with SQL NULL
  still `null`. Detection mirrors node-oracledb: the describe's `IS JSON` /
  `IS OSON` flags, exposed as the new `ColumnMetadata.udsFlags`,
  `ColumnMetadata.isJson` and `ColumnMetadata.isOson`. OSON content (magic
  `FF 4A 5A`) decodes through the OSON codec; text content as UTF-8 (with or
  without a byte-order mark) or UTF-16LE / UTF-16BE (with a byte-order mark,
  or BOM-less). Writes are unchanged — a `Map` / `List` bind already lands in
  such a column. Validated against Oracle 23ai and Oracle 21c.
- **Behavior change in 1.5.0:** such a column returned the raw `Uint8List` in
  1.4.0 and earlier, and now decodes by default. This default is the driver's
  own choice, not node-oracledb parity: node-oracledb returns the raw `Buffer`
  unless `oracledb.future.oldJsonColumnAsObj` is enabled. A value that is not
  strict JSON fails the call loudly with `OracleException`
  (`oraUnsupportedType`, naming the column) instead of returning bytes — this
  includes values the default *lax* `IS JSON` constraint accepts, such as
  unquoted field names, single-quoted strings, upper-case `TRUE`, and a
  zero-length `EMPTY_BLOB()`. Corrupt OSON instead keeps the OSON decoder's
  error code (for example, `oraProtocolError`).
  `CLOB` / `VARCHAR2` / `RAW` `IS JSON` columns, plain `BLOB` columns, views
  and expressions over the column (which describe without the flag) are
  unchanged. The rows of a `REF CURSOR` OUT bind or a nested `CURSOR()`
  column decode the BLOB too.
- **New `OracleExecuteOptions(rawJsonBlobs: true)` opts out of that decode**
  per call: the column comes back as the stored `Uint8List` — the type 1.4.0
  returned — with no JSON validation (so lax or empty values read without an
  error) and SQL NULL still `null`. It covers every row the call returns —
  eager `execute()`, every batch of `resultSet: true`, implicit result sets
  (eager and `resultSet: true`), and the rows of a `REF CURSOR` OUT bind or
  nested `CURSOR()` column — and leaves every other column alone (a native
  `JSON` column still decodes). `OracleExecuteOptions(fetchLobs: true)` still
  returns an `OracleLob` handle over the untouched bytes and wins when both are
  set for ordinary rows; a cursor-embedded BLOB fails with `fetchLobs: true`
  because those rows cannot return LOB handles. `queryStream()` /
  `executeStream()` have no fetch options, while `executeMany()` has no
  `rawJsonBlobs` option for implicit result rows; the decode error's hint
  points callers at a separate `execute()` SELECT with `rawJsonBlobs`.
  Validated against Oracle 23ai and Oracle 21c.
- **`OracleLob.trim(newSize)`** shortens a LOB to `newSize` units (characters
  for CLOB/NCLOB, bytes for BLOB) in one round trip and sets `length`
  (node-oracledb `lob.trim()` parity, except that `newSize` is required). It
  needs a writable locator — a created temporary LOB, a LOB OUT / IN OUT bind,
  or a `SELECT ... FOR UPDATE` locator — and on a persistent LOB the change is
  part of the current transaction. The server's own errors surface unchanged
  (`ORA-22926` past the end, `ORA-22920` read-only locator, `ORA-22831` for a
  CLOB size that would split a surrogate pair), leaving the handle and the
  connection usable; a negative size throws `ArgumentError` before any round
  trip.
- **`OracleLob.refresh()`** re-reads the cached `length` and `chunkSize` from
  the server (one GET_LENGTH and one GET_CHUNK_SIZE round trip) — a
  Dart-driver addition, node-oracledb has none. A failed refresh changes
  neither value. On a read-consistent fetched locator the server reports the
  length the handle actually reads, so `length` and `read()` always agree.
- **`OracleLob.defaultStreamPieceSize`** (32,768) is the stream fallback piece
  size, now on the class. The top-level `defaultLobStreamPieceSize` export is
  `@Deprecated` and will be removed in a future major release.
- **Behavior change:** `OracleLob.read()` / `getData()` starting **past the
  cached `length`** — including any read of a handle whose cached length is
  `0`, such as an empty LOB or a fresh `createTemporary*()` handle — now asks
  the server instead of returning the empty value with no round trip. A LOB
  that really ends there costs one READ and still returns the empty value; a
  LOB that grew since the handle was fetched now returns the new data (read
  piece by piece until the requested `amount` or the server's end of data) and
  advances `length`, where 1.4.0 silently returned nothing. Reads that start
  inside the cached `length` are unchanged.

  Validated against Oracle 23ai and Oracle 21c.

### Fixes

- **`executeMany()` now rejects an oversized value in a sized bind before
  sending anything.** A `varchar` (UTF-8 bytes), `nVarchar` (UTF-16 code
  units) or `raw` (bytes) value longer than the slot's declared
  `OracleBindDef.maxSize` throws an `OracleException` (`oraBindTypeError`)
  naming the row, bind and limit, never the value. It previously reached the
  server and failed there with an opaque error (ORA-01460 on 23ai and 21c).
  Slots with no `maxSize` are still sized from the rows.
- **A multi-iteration PL/SQL `executeMany()` now shares one `timeout`.** Its
  two round trips (EXECUTE then REEXECUTE) used to each get the full timeout,
  so the real ceiling was about twice the value passed. The second now waits
  only for the remaining budget; once it is spent the connection is poisoned
  and `oraConnectTimeout` is thrown, as for any timed-out call.

- **Server-expression LOBs no longer leak session temp-LOB space.** A CLOB /
  BLOB produced by an expression — `SELECT TO_CLOB(...)` / `TO_BLOB(...)`, a
  CLOB concatenation, or a PL/SQL OUT bind the block fills from a `VARCHAR2` /
  `RAW` value or a literal — is an "abstract" LOB that holds one
  `V$TEMPORARY_LOBS.ABSTRACT_LOBS` entry until it is freed. The driver never
  freed them, so each such value stayed allocated until the session ended (a
  1,500-row `TO_CLOB` query left 1,500 behind). The driver now frees them like
  temporary LOBs (python-oracledb parity): automatically when it materializes
  the value, and on `close()` for a `fetchLobs: true` handle. The free rides
  the next `execute()`, as for every temporary LOB.
  **Behavior change:** `OracleLob.isTemporary` now reports `true` for such a
  handle. Table-row, `FOR UPDATE` and `EMPTY_CLOB()` locators are unaffected.
- **A temporary LOB OUT value rejected by its `maxSize` is freed.** When an
  OUT / `IN OUT` CLOB or BLOB bind (including `executeMany()` and DML
  `RETURNING` shapes) returned a temporary LOB longer than its declared
  `maxSize`, the error was raised before the LOB was queued for freeing, so
  each such call held one session temporary LOB until the session ended.
- **Closing one of two handles to the same temporary LOB no longer frees it
  under the other.** A created temporary LOB bound as a plain IN into a block
  that returns it as an OUT value (`p_out := p_in`) under `fetchLobs: true`
  yields a second handle on the same server LOB; closing that returned handle
  used to free the LOB on the next `execute()`, so a later read of the created
  handle failed with `ORA-22922`. The free is now queued when the last of them
  closes.

  Validated against Oracle 23ai and Oracle 21c.

- **Streaming LOB text diagnostics.** A byte that can never begin a UTF-8
  sequence in a `textStream` now fails as malformed UTF-8 data instead of being
  reported as a truncated stream, and a READ reply that omits its unit count
  advances the offset from the bytes it delivered (not decoded units), so a
  split character can no longer cause a spurious "no progress" error or a
  re-read. `OracleLob.chunkSize` is documented as a byte count for every LOB
  type (verified against `DBMS_LOB.GETCHUNKSIZE` on 23ai and 21c).

- **Implicit result sets (`DBMS_SQL.RETURN_RESULT`) whose rows carry a
  CLOB / NCLOB / BLOB or native JSON column now decode**, eager and lazy
  (`resultSet: true`), and under `fetchLobs: true` (eager) yield `OracleLob`
  handles. Previously the first FETCH of such a cursor failed with ORA-12547
  ("Integer too large: size=114"), and on Oracle 21c the malformed stream
  left the connection unusable. As in node-oracledb (`requiresDefine`), the
  driver now sends the cursor's LOB-prefetch defines before its first fetch.
  REF CURSOR OUT binds and nested `CURSOR()` columns carrying such a column
  get the same defines and decode too (`fetchLobs: true` still rejects a LOB
  there). Validated against Oracle 23ai and Oracle 21c.
- **`preserveTimestampTimeZone: true` now applies to the first row batch of a
  query that selects a CLOB / NCLOB / BLOB or native JSON column.** That
  batch arrives in the driver's DEFINE round trip, which decoded `TIMESTAMP
  WITH TIME ZONE` values as a UTC `DateTime` while later batches returned
  `OracleTimestampTz` — for example `SELECT TO_CLOB('x'), ts FROM ...`. Eager
  `execute()` and `resultSet: true` are both fixed. Validated against Oracle
  23ai and Oracle 21c.
- **Behavior change:** a repeated SELECT of a native JSON column now re-parses
  its cached cursor, as CLOB / BLOB queries already did, instead of reusing it
  without fresh defines. The statement-cache slot is kept, and results are
  unchanged.
- **JSON bind hardening.** JSON bind values (`Map` / `List` DML and
  `executeMany()` binds, `OracleBind.inOut(type: OracleDbType.json)`) are
  now validated once per bind (previously up to three walks), and:
  - **Behavior change:** NaN and ±Infinity are rejected by default — as a
    member or as a declared scalar root — with an `ArgumentError` naming the
    member's path but never the value (`OracleException` with
    `oraBindTypeError` from `executeMany()`), so a stray NaN from an
    arithmetic bug no longer lands in the database. Opt in per bind with the
    new `OracleBind.inOut(..., allowNonFinite: true)` (JSON only) to send
    them as `BINARY_DOUBLE` as before. DML and `executeMany()` binds have no
    opt-in, so a fetched document holding NaN / ±Infinity re-binds only
    through a PL/SQL `IN OUT JSON` parameter. Finite doubles outside
    `NUMBER`'s range still need no opt-in.
  - A cyclic value (a map or list that contains itself) or one nested deeper
    than 1000 levels (Oracle's JSON limit) now fails with an `ArgumentError`
    at the call site instead of overflowing the stack. A sub-document shared
    by two members is not a cycle.
  - **Behavior change:** a UTC `DateTime` (`isUtc`) now binds as
    `TIMESTAMP WITH TIME ZONE` at `+00:00` and fetches back as an
    `OracleTimestampTz` for the same instant; previously its UTC fields were
    stored zone-less, as if they were local wall-clock time. Local `DateTime`
    binds are unchanged, byte for byte.
  - Field names of 256–65535 UTF-8 bytes now bind on Oracle 23ai (OSON
    version 3), so a document fetched from 23ai with such a name re-binds.
    Long names are filed in the order the server searches them (by their
    16-bit hash id, measured live), so `JSON_VALUE` finds every one. On older
    servers such names still fail at the call site: Oracle 21c would accept
    the document but could not read it back (`JSON_SERIALIZE` raises
    ORA-40441). Names over 65535 bytes always fail.
  - A declared-JSON `String` root is still a JSON string scalar, never
    parsed (now documented).

  Validated against Oracle 23ai and Oracle 21c.

## 1.4.0

Public LOB streaming and temporary LOBs — `OracleLob`. CLOB, NCLOB and BLOB
values can now be worked with as server-backed handles instead of being
materialized whole: read bounded ranges, write in place, stream a value in or
out piece by piece, create session-duration temporary LOBs, and consume a
streaming result set that hands back a handle per row. All additive — no
breaking changes — and validated against Oracle 23ai and Oracle 21c (155/155
focused LOB integration tests green on both, plus the full suites: 563 pass /
32 skip on 23ai and 564 pass / 31 skip on 21c, and the UTF-8-form CLOB read
path additionally proven live against a `WE8MSWIN1252` database).

### Features

- **`OracleLob` handle** — obtained with `OracleExecuteOptions(fetchLobs: true)`
  instead of a materialized `String` / `Uint8List`. Exposes `read()` (alias
  `getData()`) for a bounded, 1-based range in the type's native units
  (characters for CLOB/NCLOB, bytes for BLOB), `write(offset, value)`,
  `length`, `chunkSize`, `type`, `isTemporary`, `isClosed`, and `close()`.
  Reads and writes are ordinary round trips on the owning connection, so an
  open **fetched** handle holds that connection's single in-flight slot until
  it is closed; liveness is consulted rather than mirrored, so a handle whose
  connection closes, resets or breaks reports `isClosed == true` immediately.
- **`read()` has no round-trip size ceiling** — a range that one round trip
  cannot deliver continues with further READs at the advanced offset. Pieces
  are assembled as **bytes** and decoded exactly once, so a piece boundary
  falling inside a UTF-8 sequence or a UTF-16 surrogate pair can never corrupt
  the value. Every size measured on 23ai (to 32 MB) and 21c (to 8 MB) still
  arrives in exactly one READ, so the common case costs one round trip.
- **Temporary LOBs** — `createTemporaryClob()`, `createTemporaryNClob()` and
  `createTemporaryBlob()` create an empty session-duration LOB on the server
  and hand back a caller-owned handle. `close()` frees the server-side LOB
  through the existing free-temp piggyback, which rides the next statement. A
  temporary handle is exempt from the in-flight-slot rule, so it can be used
  and bound while open, and it survives `commit()` and `rollback()` (session
  duration, not transaction duration).
- **A created-temporary `OracleLob` as a bind value** — pass a
  `createTemporaryClob()`/`createTemporaryNClob()`/`createTemporaryBlob()`
  handle straight into `INSERT ... VALUES (:v)`, a PL/SQL IN bind, or an
  `OracleBind.inOut` spec. Binding a closed handle, or one belonging to another
  connection, fails before any wire round trip. A **fetched** handle (from
  `fetchLobs: true`) cannot be bound: it holds the connection's single in-flight
  slot while open, so the binding statement is rejected as a concurrent
  operation, now with an error that names this restriction instead of the
  generic concurrency text.
- **Streaming transfer** — `textStream({offset, pieceSize})` (CLOB/NCLOB),
  `byteStream({offset, pieceSize})` (BLOB) and
  `writeStream(Stream<Object> data, {offset})`, with the exported
  `defaultLobStreamPieceSize` (32,768) default. One READ per emitted piece, one
  WRITE per caller chunk; `pieceSize` defaults to the server's `chunkSize`. The
  read streams stop on the server's empty READ rather than at the cached
  `length`, so they are immune to a stale prefetched length, and the driver
  stitches its own piece boundaries — a split surrogate pair or multi-byte
  sequence is carried over, never substituted. Cancelling a stream mid-flight
  leaves the connection immediately reusable.
- **`resultSet: true` + `fetchLobs: true`** for a top-level SELECT — a
  streaming result set yields an `OracleLob` per row, and a LOB read between
  two `getRow()` calls does not disturb the cursor. Handles wrapped for a
  prefetched batch but never delivered are reaped by `OracleResultSet.close()`,
  by a mid-stream FETCH failure, and by pool reclaim, so a caller that stops
  iterating early can never wedge the connection.
- **`OracleResult.closeLobs()`** — bulk-closes every handle a result carries,
  including those buffered by a streaming result set.
- **Fail-loud boundaries** (all before or instead of returning wrong data): a
  LOB column carried by a nested `CURSOR()` or a REF CURSOR OUT bind is
  rejected under `fetchLobs` (and every nested server cursor in that batch is
  requeued for close rather than leaked) — note this query shape is not usable
  at all, `fetchLobs` or not: it fails with a protocol error on 23ai and 21c,
  and on 21c the session is lost. Because every LOB pre-check runs on
  already-decoded rows, `fetchLobs: true` reaches the rejection only for the
  REF CURSOR OUT-bind half (after the execute round trip, but before the
  poisoning row FETCH); for a nested `CURSOR(...)` column the EXECUTE response
  fails to decode first, so `fetchLobs` changes nothing and projecting the LOB
  outside the cursor is the only remedy (see README "Known Limitations");
  `resultSet: true` + `fetchLobs: true` on a PL/SQL block
  with lazily-drained implicit results is rejected pre-wire; `executeMany()`
  with an `OracleLob` bind value is rejected; writing through a read-only
  plain-`SELECT` locator surfaces the real Oracle error (ORA-22920) and leaves
  the handle and connection usable.

### Bug Fixes

- **A temporary LOB the server allocated for a materialized LOB value is now
  freed** instead of leaking session temporary-LOB space until the session
  ended. Measured on 23ai and 21c: three consecutive
  `OracleBind.inOut(value: <String>, type: OracleDbType.clob)` PL/SQL calls
  under the default `fetchLobs: false` grew `V$TEMPORARY_LOBS` by exactly one
  per call, because the OUT locator was read into a `String` and then
  discarded with nothing left to free it. The materialize path now queues a
  locator whose flag byte marks it temporary onto the existing free-temp
  piggyback. The values callers receive are byte-for-byte unchanged; only the
  free accounting differs, and locators the server does not mark temporary
  (table rows, `TO_CLOB(...)` expressions, `FOR UPDATE` locators, an OUT bind
  the PL/SQL body fills from a `TO_CLOB` literal) are unaffected. Internal
  hardening that came with the fix: because the materialize path is a second
  owner able to queue a temporary locator, the free queue now also dedupes at
  the locator level — a PL/SQL `IN OUT` LOB bind whose body does not allocate a
  new LOB (`p := p`) hands back the very locator the driver created for the
  input value, which was already queued, and queueing it twice would have
  surfaced as an error on the unrelated statement the piggyback rides.

## 1.3.0

Bulk DML — `executeMany()`. A single wire round trip now executes one statement
many times: Oracle array DML for INSERT/UPDATE/DELETE/MERGE (including
`RETURNING ... INTO` array OUT binds), and repeated PL/SQL execution with
per-iteration IN, OUT, and IN OUT binds (node-oracledb `executeMany` parity).
All additive — no breaking changes — and validated against Oracle 23ai and
Oracle 21c (53/53 focused `executeMany` integration tests green on both).

### Features

- **`OracleConnection.executeMany(sql, rowsOrNumIterations, [options])`**: run
  one statement across many bind sets in a single round trip. Pass a non-empty
  list of bind rows (a `List` for positional `:1`/`:2` SQL, a `Map` for named
  `:name` SQL), or — for PL/SQL blocks that need no per-iteration input — a
  positive `int` iteration count (node-oracledb `numIterations` form). Reuses
  the same bind parsing/ordering pipeline, statement caching, one-in-flight
  concurrency guard, and transaction semantics as `execute()` (no auto-commit).
- **Array DML** (INSERT/UPDATE/DELETE/MERGE): each slot's Oracle type is
  inferred from the first non-null value and must stay consistent across rows;
  string/RAW slots are sized to the largest value; `rowsAffected` is the total
  row count. Rows may be shorter than the placeholder count (missing trailing
  values bind SQL NULL).
- **DML `RETURNING ... INTO`**: per-row generated values, ROWIDs, or updated
  column values come back through array OUT binds. Results are row-major, one
  entry per input row, each holding a list of returned values per OUT bind
  (an input row that matches no database rows yields an empty list).
- **Bulk PL/SQL array binds** via `OracleBindDef`
  (`OracleBindDef.input` / `.output` / `.inputOutput`): declare each
  placeholder's type and direction once in `OracleExecuteManyOptions.bindDefs`
  (`List` for positional SQL, `Map<String, OracleBindDef>` for named). OUT
  results are row-major, one entry per iteration.
- **Row-level batch errors** (`OracleExecuteManyOptions(batchErrors: true)`):
  DML applies every valid row and reports each failed row's data error as an
  `OracleBatchError` (with its 0-based input `offset`) in
  `OracleResult.batchErrors` instead of throwing on the first failure.
  Statement-level failures still throw. DML only.
- **Per-row DML row counts** (`OracleExecuteManyOptions(dmlRowCounts: true)`):
  `OracleResult.dmlRowCounts` holds one affected-row count per input row, in
  input order. DML only; requires Oracle Database 12 or later.
- **Fail-loud scope**: SELECT/`WITH ... SELECT` queries, `SYS_REFCURSOR` OUT
  binds, PL/SQL collection binds, `OracleBind` value specs inside rows,
  RETURNING without `bindDefs`, and `bindDefs` on plain (non-returning) array
  DML all fail before any wire round trip.

## 1.2.0

Non-`AL32UTF8` database character set compatibility. The driver always
negotiates UTF-8 (`AL32UTF8`) on the wire and lets the Oracle server convert to
and from the database's own character set — so `VARCHAR2`/`CHAR`/`CLOB` text
round-trips correctly on single-byte and other non-`AL32UTF8` databases, not
just `AL32UTF8`. All additive — no breaking changes — and validated against
Oracle 23ai and Oracle 21c, with the non-`AL32UTF8` round-trip proven
end-to-end against a `WE8MSWIN1252` database.

### Features

- **Non-`AL32UTF8` database character sets** (`VARCHAR2` / `CHAR` / `CLOB`):
  primary character data round-trips through Oracle's server-side conversion
  while the client always negotiates UTF-8, so the database character set is
  transparent to your code. Validated end-to-end against `WE8MSWIN1252`
  (Windows-1252 Western European) using code-page-specific characters — euro
  sign, smart quotes, en/em dashes, ellipsis, bullet — so the round-trip proves
  real UTF-8 ⇆ server conversion rather than a byte-identity accident.
- **National character types** (`NCHAR` / `NVARCHAR2` / `NCLOB`): supported when
  the database's national character set is `AL16UTF16` (the standard,
  non-deprecated national charset used by both validated server lines). Values
  travel the wire as UTF-16BE and map to Dart `String`; bind with
  `OracleDbType.nVarchar` or `OracleDbType.nClob`.
- **Character-set diagnostics** (`connection.charsetInfo`): exposes the detected
  `databaseCharset` / `nationalCharset` and `supportsNationalCharacterSet`
  (`OracleCharsetInfo`).
- **Fail-loud on unsupported national character sets**: a connection whose
  national charset is not `AL16UTF16` (e.g. the deprecated `UTF8` national
  charset) raises an `OracleException` on any `NCHAR` / `NVARCHAR2` / `NCLOB`
  bind or column instead of silently producing mojibake. Ordinary
  `VARCHAR2` / `CHAR` / `CLOB` columns are unaffected and keep working over the
  UTF-8 wire path.

### Bug Fixes

- **DataTypes capability length prefix is overflow-safe**: the compile-caps
  length prefix is guarded against single-byte overflow during the DataTypes
  negotiation, hardening the classical (pre-23ai) handshake path.
- **Negotiated TTC field version is emitted in the compile-caps slot**: the
  transport now writes the negotiated `_ttcFieldVersion` into the compile-caps
  slot, keeping the capability exchange consistent across supported server
  versions.

## 1.1.0

Server-side cursor support: queries can now be streamed instead of fully
materialized, PL/SQL `REF CURSOR` OUT binds and implicit result sets are
consumable, and `CURSOR()` columns nested inside a query are materialized
inline. All additive — no breaking changes — and validated against Oracle 23ai
and Oracle 21c.

### Features

- **Streaming result sets** (`OracleResultSet`): pass
  `OracleExecuteOptions(resultSet: true)` to `execute()` to receive a
  cursor-backed `OracleResultSet` in `OracleResult.resultSet` instead of
  materializing every row. Read incrementally with `getRow()` / `getRows([n])`,
  inspect `columnNames` before the first fetch, tune the batch size with
  `fetchSize`, and `close()` to release the server cursor and free the
  connection for reuse.
- **Row streams** (`queryStream()` / `executeStream()`): read a `SELECT`'s rows
  as a `Stream<OracleRow>` for incremental consumption. Cancelling the
  subscription early closes the underlying cursor and returns the connection to
  a usable state.
- **REF CURSOR OUT binds**: bind a PL/SQL `SYS_REFCURSOR` as an OUT parameter
  with `OracleBind.out(type: OracleDbType.cursor)` and consume the returned
  cursor as a result set. (`IN OUT` cursor binds are intentionally unsupported.)
- **PL/SQL implicit result sets**: cursors returned by `DBMS_SQL.RETURN_RESULT`
  surface in `OracleResult.implicitResults` (node-oracledb parity name), in
  server-returned order — eager `List<OracleRow>` per cursor by default, or
  lazy `OracleResultSet` handles under `OracleExecuteOptions(resultSet: true)`.
- **Nested cursor columns**: a `CURSOR(SELECT ...)` column in a query projection
  materializes inline on the parent row as a `List<OracleRow>` (an empty nested
  cursor is `[]`, a NULL cursor column is `null`), across the eager,
  `queryStream()`, and `resultSet: true` paths.
- **`maxRows` cap** (`OracleExecuteOptions(maxRows: N)`): bounds how many rows
  the eager paths materialize (`0` = unlimited), matching node-oracledb's
  `maxRows`. `OracleResult.moreRowsAvailable` reports when the result was
  truncated.

### Bug Fixes

- **Connection ping no longer desyncs the TTC stream**: ping is now issued as a
  proper FUNCTION RPC whose reply is fully drained, so the next operation on a
  pooled connection after a ping can no longer read a stale, misframed
  response.
- **Cursor reclamation is identity-based**: result-set and embedded-cursor
  cleanup now matches the exact statement that owns a cursor (with a result-set
  `cursorId 0` guard), preventing a cursor from being reclaimed against the
  wrong statement.
- **Embedded cursors are reaped on fail-loud describe validation**: when a
  describe mismatch is rejected, the associated server cursor ids are now
  released instead of leaked.
- **Pool reclaim surfaces a clear error to live stream subscribers**: a pool
  reclaim that races an open result-set stream now reports an explicit error to
  the subscriber rather than failing obscurely.
- **Network-unreachable errors map cleanly**: host/network-unreachable socket
  `OSError`s are now mapped to `oraHostUnreachable` instead of a generic error.

## 1.0.0

First stable release. Connection pooling — the milestone the 0.9.0 notes named
as the 1.0 gate — is complete, and the public API now follows semantic
versioning (breaking changes bump the major version). The full driver is
validated against Oracle 23ai and Oracle 21c.

### Features

- **Connection pooling** (`OraclePool`): `create()` builds a pool of prewarmed,
  authenticated sessions (`minConnections`/`maxConnections`); `acquire()` /
  `release()` borrow and recycle sessions, rolling back uncommitted work on
  release; `withConnection()` wraps the acquire/release pair leak-safely;
  `acquireTimeout` bounds queued waits when the pool is exhausted; `idleTimeout`
  shrinks surplus idle sessions back toward `minConnections`;
  `close(drainTimeout: ...)` drains borrowed sessions on shutdown; and session
  tagging (`acquire(tag: ...)` with an optional `sessionCallback`) reuses
  session state such as NLS settings across borrowers.

### Bug Fixes

- **Pooled sessions recover from cross-session DDL transparently**: a cached
  `SELECT` cursor whose result shape changed under it (e.g. a column dropped by
  another session) reported `ORA-01007` / `ORA-00932` to the caller on
  re-execute. The driver now mirrors node-oracledb — for queries, on those two
  describe-mismatch codes, it clears the dead cursor and re-executes once as a
  full parse — so the caller sees correct rows instead of a spurious error.
  Bounded to a single retry; integrity/constraint violations are never retried.
- **No connection leak when a pool is closed mid-prewarm**: `OraclePool` now
  rechecks the closed flag after each connection open during prewarm and
  destroys a connection opened after `close()` rather than parking it into the
  drained idle set.
- **`close(drainTimeout:)` waits for in-flight opens**: the close drain now
  accounts for grow-on-demand / waiter-provision connection opens still in
  flight, so a positive `drainTimeout` resolves only once those have landed and
  self-disposed rather than while a socket teardown is still pending.

## 0.9.3

Large-object and binary type support, JSON, plus protocol hardening.

### Features
- **CLOB**: read and write Character Large Objects; inline binding for values up to 32,767 bytes, temp-LOB protocol for larger payloads.
- **BLOB**: read and write Binary Large Objects with the same inline/temp-LOB routing boundary.
- **RAW**: read and write `RAW` columns with comprehensive edge-case coverage.
- **JSON**: native `OracleDbType.json` bind type; values are encoded/decoded via OSON; `JSON` column support requires a tablespace with 8k+ block size.

### Bug Fixes
- Malformed TTC streams now fail loudly instead of spinning the receive loop, surfacing protocol corruption as an error rather than a hang.
- TIMESTAMP payloads of lengths other than 7/11/13 bytes are now tolerated, matching node-oracledb decode behavior.
- `RETURN_PARAMETER` key-value and registration sections are now read unconditionally, fixing edge cases in PL/SQL returning clauses.
- OUT-bind `maxSize` is now validated before the network round-trip; oversized values are rejected with a clear error rather than a server-side failure.
- Single-round-trip BLOB read guard prevents partial reads from silently truncating large binary results.
- OSON zero-length number now encodes to the same wire representation as node-oracledb (parity fix).

### Documentation
- Add a project reference set (overview, architecture, API reference, development guide) under `docs/`.
- Document the tablespace requirement for creating JSON columns.

## 0.9.2

### Bug Fixes
- Reverted a false-positive protocol-error guard on multi-batch column-count mismatches: Oracle legitimately sends fewer column bytes than the total column count during multi-batch fetches, and the guard was incorrectly raising `oraProtocolError` on valid server responses.
- `ClientInfo` static finals in `auth_message.dart` are now guarded with try-catch IIFEs, matching the safe pattern already used in `fast_auth_message.dart`, preventing crashes if the environment is partially unavailable during connection setup.

### Documentation
- Update README platform support to reflect Android and iOS as declared native Dart targets while keeping web explicitly unsupported.
- Keep README dependency examples aligned with the package version.

### Tooling
- Add a README version-sync helper and wire it into CI, publish, and release bumping so future releases fail before publishing if README dependency references drift from `pubspec.yaml`.

## 0.9.1

### Packaging
- Android and iOS added to the supported platforms list. The transport layer uses only `dart:io` TCP sockets (`Socket`, `SecureSocket`) which are available on both mobile platforms — no code changes were required.

## 0.9.0

First stable-leaning release. The core driver — connections, authentication, queries, DML, transactions, statement caching, and PL/SQL — is validated against Oracle 23ai and Oracle 21c. LOB (CLOB/BLOB), RAW, and JSON type support landed in 0.9.3. 1.0.0 will follow once connection pooling lands.

### Features
- PL/SQL execution: stored procedures and functions with OUT / IN OUT bind parameters via `OracleBind.out` / `OracleBind.inOut`; values returned through `OracleResult.outBinds` (by name or position)
- TIMESTAMP WITH TIME ZONE support: decoded as a UTC `DateTime` by default, or as `OracleTimestampTz` preserving the original offset when connecting with `preserveTimestampTimeZone: true`
- `OracleDbType.timestampTz` for PL/SQL OUT / IN OUT binds of `TIMESTAMP WITH TIME ZONE` parameters; OUT values follow the connection's decode contract (UTC `DateTime` by default, `OracleTimestampTz` on a `preserveTimestampTimeZone: true` connection)
- `OracleResult.moreRowsAvailable`: `true` whenever the driver could not fully drain the result set (the result is then a truncated prefix) — either the 1,000-batch fetch safety cap stopped the drain early, or the server reported more rows pending on a cursor the driver had no usable cursor id to keep fetching
- `OracleTimestampTz` now implements `Comparable` (ordering by the UTC instant, tie-breaking on `offsetMinutes`, so `compareTo == 0` iff `==`), stores the offset as a single `offsetMinutes`, and adds a `fromHourMinute` factory (`tzHourOffset`/`tzMinuteOffset` remain available as getters). `OracleTimestampTz` is new in 0.9.0 and was never published in any earlier release, so the `offsetMinutes` constructor shape is not a breaking change for released users

### Bug Fixes
- SELECT results were silently capped at 50 rows in all previous 0.1.0-alpha releases; full result sets are now fetched (bounded by a 1,000-batch safety cap)
- Re-executing a cached multi-batch SELECT no longer truncates the result to one prefetch window: the server echoes cursor id 0 on a cached-cursor re-execute, and the fetch drain now falls back to the request's own cursor id (`moreRowsToFetch` is cleared only by ORA-01403, matching node-oracledb thin semantics)
- Duplicate-column bit vectors are now cleared after every decoded row (a stale vector silently sheared all later columns of the next row), and a duplicate marked on the first row of a FETCH round is resolved against the last row of the previous round; a duplicate with no prior row anywhere raises a protocol error on the strict decode pass instead of a misaligned decode (the lenient stream-completion probe instead skips the marker byte-accurately and substitutes null, by design)
- PL/SQL OUT binds of `TIMESTAMP WITH TIME ZONE` now honor the connection's `preserveTimestampTimeZone` flag (previously they always decoded to a UTC `DateTime`)
- A plain `DateTime` bound under `OracleDbType.timestampTz` is now encoded as its UTC instant at an explicit `+00:00` offset (full 13-byte payload) — the server mishandles an offset-less 11-byte TSTZ bind and echoes invalid zone bytes back, corrupting the round-trip
- `OracleTimestampTz.fromOffset` now rejects all sub-minute offsets (a sub-second remainder such as `milliseconds: 500` previously slipped through)
- `OracleException.code` is total: a negative (invalid) error code renders as `ORA-invalid(<code>)` instead of throwing; `toString` delegates to it unconditionally

### Hardening
- Malformed `TIMESTAMP WITH TIME ZONE` wire payloads (zone offset past the +14:00 ceiling, mixed-sign hour/minute bytes, or a short 7/11-byte payload on the TSTZ decode path) raise `OracleException` (protocol error) — never `ArgumentError` or a silently fabricated `+00:00` offset
- CI: the duplicated Oracle readiness probes for the 23ai and 21c integration jobs are extracted into one parameterized `scripts/ci_wait_for_oracle.sh`
- Protocol-version gating for pre-23ai servers (12.2 through 23ai TTC field versions) and a hardened classical AUTH_PHASE_ONE/TWO path
- Receive-loop exhaustion caps, transport poisoning on timeout, and fail-loud auth state transitions
- NUMBER/DATE/TIMESTAMP codec guards: NaN/Infinity rejection at bind construction, BCE date rejection, exponent-range checks
- Statement-cache correctness: DDL invalidation, bind-type signatures in the cache key, FOR UPDATE exclusion
- Unit test suite grown to ~818 tests; CI runs integration suites against both Oracle 23ai and Oracle 21c with a coverage floor

### Packaging
- `pubspec.yaml` now declares supported platforms explicitly: macOS, Windows, Linux (mobile untested, web unsupported)
- Minimum Dart SDK raised from 3.3.0 to 3.12.0

## 0.1.0-alpha.5

Improves pub.dev analysis score and repository presentation.

### Bug Fixes
- Use exact canonical Apache 2.0 license text recognized by `pana` to fix license analysis on pub.dev
- Fix CI badge URL in README

## 0.1.0-alpha.3

Fixes a missing permission in the publish workflow that prevented package releases.

### Bug Fixes
- Add `contents: read` permission to the publish GitHub Actions workflow to allow package publishing to succeed

## 0.1.0-alpha.2

Resolves pub.dev publish warnings and improves package scoring by fixing the library name, license, and adding a working example.

### Features
- Add `example/example.dart` with a working usage example, satisfying pub.dev's example requirement (+10 pub points)

### Bug Fixes
- Rename `lib/dart_oracledb.dart` to `lib/oracledb.dart` to match the package name convention required by pub.dev
- Restore canonical Apache 2.0 license text so pana correctly identifies it as an OSI-approved license (+10 pub points)
- Add `.pubignore` to exclude `reference/`, `_bmad/`, `scripts/`, and `docker-compose.yml` from the published package
- Add `CHANGELOG.md` as required by pub.dev

## 0.1.0-alpha.1

Initial alpha release.

### Features

- TCP connection to Oracle Database via direct TNS/TTC wire protocol — no Oracle Instant Client required
- Authentication: FAST_AUTH single-round-trip (Oracle 23ai) and classical AUTH_PHASE_ONE/AUTH_PHASE_TWO (Oracle 21c and earlier)
- `OracleConnection.connect` and `OracleConnection.withConnection` factory methods
- `execute()` — SELECT queries and DML (INSERT, UPDATE, DELETE) with named and positional bind parameters
- `commit()`, `rollback()`, `runTransaction()` — transaction management
- `ping()` — connection health check
- Transparent statement cache (configurable size)
- TLS/SSL encrypted connections via `TlsConfig`
- `OracleResult` / `OracleRow` — row access by column name (case-insensitive) or index, `toMap()` helper
- ~490 unit tests; integration test suite validated against Oracle 23ai and Oracle 21c

### Platforms

macOS, Windows, Linux, iOS, Android (not web — requires `dart:io` TCP sockets).

