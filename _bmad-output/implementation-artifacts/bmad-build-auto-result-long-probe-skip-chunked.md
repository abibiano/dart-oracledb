---
status: done
---

# BMad Build Auto Result

## Auto Run Result

Status: done

DW-142: `ReadBuffer.skipBytesChunked()` now walks 0xFE chunk headers and
advances the position without collecting views or allocating; the non-strict
LONG/LONG RAW probe uses it (skipSB4/skipUB4 unchanged). Unit tests added in
`test/src/protocol/buffer_test.dart` (null/short/chunked/multi-byte/truncated,
position parity with `readBytesWithLength`).

Verification: unit suite 2413 passed; integration passed on Oracle 23ai
(1521/FREEPDB1, 887 passed) and 21c (1522/XEPDB1, 856 passed).
