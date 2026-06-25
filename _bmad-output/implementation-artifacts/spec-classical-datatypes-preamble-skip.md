---
title: 'Classical DataTypes RESPONSE parser preamble/caps skip — investigation and dismissal'
type: 'investigation'
created: '2026-06-25'
status: 'done'
baseline_commit: 'bf84182dae5078f928424f2febd5354ccb0afc16'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Deferred-work concern (item 2, "## Open"):** "Classical DataTypes response
parser may have misaligned preamble skip vs the FAST_AUTH path: the parser does
not skip the 5-byte charset/flags preamble or the two length-prefixed caps
blocks before entering the data-type mapping loop. Pre-existing; integration
tests pass on both 23ai and 21c. [lib/src/transport/transport.dart]"

**Goal:** Determine whether the classical-path DataTypes RESPONSE parser is
actually misaligned relative to the FAST_AUTH path, using node-oracledb's thin
client as the source of truth, and either fix it (both paths align) or dismiss
the item with cited rationale.

</frozen-after-approval>

## Investigation (byte-level, against current source + node-oracledb)

### What the two Dart paths do

There are in fact **three** distinct notions of the DataTypes layout in
`lib/src/transport/transport.dart`, and only one of them parses the RESPONSE on
the classical path:

1. **Classical RESPONSE parser** — `_sendDataTypesNegotiation` →
   (now) `parseDataTypesResponse` (transport.dart ~2300):
   reads the 1-byte message type, then **immediately** the data-type mapping
   loop (`readUint16BE` pairs until a `0x0000` terminator). **No 5-byte
   preamble, no caps blocks.**

2. **FAST_AUTH offset-tracking walk** — `sendFastAuth` inline `dtBuffer`
   (transport.dart ~2142): reads the type byte, then `skip(5)` (charset 2 +
   nCharset 2 + flags 1), then a length-prefixed compile-caps block and a
   length-prefixed runtime-caps block, **then** the mapping loop — followed by
   a fallback "scan forward until byte == 8 (AUTH parameter message)" loop.
   This is NOT a parser of the DataTypes response shape; it is an ad-hoc walker
   used to find the byte offset where the next concatenated message (AUTH)
   begins inside a single multi-message FAST_AUTH response buffer, and it is
   backstopped by the `b == 8` scan when the offset math is off.

3. **`DataTypesResponse.decode`** (protocol_message.dart ~228): type byte +
   two length-prefixed caps blocks, no mapping loop. Called once in the
   FAST_AUTH path purely for logging; its return value is discarded.

The deferred note compares (1) against (2) and concludes (1) is "missing" the
preamble/caps skip that (2) performs.

### What node-oracledb does (source of truth)

`reference/node-oracledb/lib/thin/protocol/messages/dataType.js`
`DataTypeMessage.processMessage` (lines 41–55):

```js
processMessage(buf, messageType) {
  if (messageType === constants.TNS_MSG_TYPE_DATA_TYPES) {
    while (true) {
      const dataType = buf.readUInt16BE();
      if (dataType === 0) break;
      const convDataType = buf.readUInt16BE();
      if (convDataType !== 0) buf.skipBytes(4);
    }
    ...
```

The 1-byte message type is consumed by the dispatcher BEFORE `processMessage`
(`base.js` `process()` lines 376–384: `const messageType = buf.readUInt8();
this.processMessage(buf, messageType);`). So the node-oracledb DataTypes
**RESPONSE** body is parsed as **just the mapping loop** — there is NO 5-byte
charset/flags preamble and NO caps blocks on the response side. The 5-byte
preamble + the two `writeBytesWithLength` caps blocks appear ONLY in
`DataTypeMessage.encode` (the REQUEST, lines 57–72).

Critically, this is the SINGLE handler used by BOTH negotiation paths:
`reference/node-oracledb/lib/thin/protocol/messages/fastAuth.js`
`processMessage` (lines 63–79) dispatches `TNS_MSG_TYPE_DATA_TYPES` straight to
`this.dataTypeMessage.processMessage(buf, messageType)`. So node-oracledb parses
the DataTypes response identically on FAST_AUTH and classical — type byte +
mapping loop, nothing else.

### Why the classical path doesn't bite today, and wouldn't under any charset

The classical path (`sendProtocolNegotiation` → `_sendDataTypesNegotiation`)
issues the DataTypes request as its OWN round trip (`sendData` + `receiveData`),
SEPARATE from the Protocol round trip. So `receiveData()` returns a **standalone**
buffer containing exactly one DataTypes response: `[type][mapping loop][0x0000]`
— no Protocol message ahead of it and no AUTH message after it. There is no
preamble or caps to skip, and adding such a skip (as the note proposes) would
consume real mapping-loop bytes and desync the parse. The shape is charset- and
version-independent (the preamble/caps the note refers to are a property of the
REQUEST the client builds, not of the server's response), so the
`oracle-non-al32` fixture would not expose any latent bug here either.

## Verdict — DISMISSED (node-oracledb parity)

The premise is **inverted**. The classical RESPONSE parser (type byte +
mapping loop) is the CORRECT one and matches node-oracledb's
`DataTypeMessage.processMessage` exactly. It is the FAST_AUTH path's extra
5-byte-preamble + caps skip (path 2 above) that does not mirror the
node-oracledb response structure — but that walk is an offset finder for a
concatenated multi-message buffer, not a response parser, and it is backstopped
by an AUTH-message scan, so it is a SEPARATE concern and out of scope for this
item. No alignment change is warranted on the classical path; making it skip a
non-existent preamble/caps would be the actual bug.

To keep the dismissal robust, the classical response-drain loop was extracted
verbatim into a `@visibleForTesting static Transport.parseDataTypesResponse`
(pure refactor — same bytes consumed; the only substantive change is the message
type literal `2`, kept as a literal because the `ttcMsgTypeDataTypes` constant is
exported by two imported libraries and is ambiguous unqualified, matching the
encode path's existing convention) so a future "fix" that wrongly adds a
preamble/caps skip is caught by a unit test.

## Acceptance Criteria

- **AC1 — Parity documented and cited.** Given node-oracledb's
  `dataType.js`/`fastAuth.js`/`base.js`, When the DataTypes response is parsed,
  Then it is type byte (consumed by the dispatcher) + mapping loop only, with no
  preamble/caps skip — and the classical Dart parser matches this.
- **AC2 — Behavior pinned.** Given a standalone classical DataTypes response
  `[type 2][dataType,convType pairs][0x0000]`, When
  `Transport.parseDataTypesResponse` runs, Then it drains the whole buffer to the
  terminator without throwing (incl. the empty-mapping-list case).
- **AC3 — Divergence proven.** Given the same real response bytes, When a
  hypothetical parser that skips a 5-byte preamble + two caps blocks runs, Then
  it over-reads and throws (`BufferUnderflowException`), while
  `parseDataTypesResponse` consumes them cleanly — proving the ABSENCE of the
  skip is load-bearing, not incidental.
- **AC4 — No regression.** Given the refactor is a verbatim extraction,
  When `dart analyze` and the focused transport unit file run, Then analyze is
  clean and all transport unit tests pass.
- **AC5 — Dual-env green.** Given the classical DataTypes negotiation runs on
  every 21c connection, When the full integration suite runs on both Oracle
  23ai and 21c, Then both pass.
- **AC6 — Deferred-work updated.** Item 2 is removed from "## Open" and recorded
  as DISMISSED (node-oracledb parity), dated 2026-06-25, leaving items 4 and 5
  untouched.

## Validation results

- `dart analyze`: **No issues found.**
- `dart test test/src/transport/transport_test.dart`: **55/55 pass** (52 prior +
  3 new `parseDataTypesResponse` parity tests).
- Integration 23ai (FAST_AUTH): **421 pass / 28 skip.**
- Integration 21c (classical AUTH — exercises `parseDataTypesResponse`):
  **422 pass / 27 skip.**

## Files

- `lib/src/transport/transport.dart` — extracted
  `@visibleForTesting static parseDataTypesResponse` from
  `_sendDataTypesNegotiation` (verbatim drain loop + doc comment citing
  node-oracledb).
- `test/src/transport/transport_test.dart` — new
  `parseDataTypesResponse (classical DataTypes response parity)` group (3 tests,
  incl. a proven-to-fail preamble-skip divergence control).
- `_bmad-output/implementation-artifacts/deferred-work.md` — item 2 dismissed.
