# FAST_AUTH Implementation - Continuation Guide

**Date:** 2025-12-16 (Updated: Session 4)
**Story:** 1-4-fix-authentication-protocol-debugging
**Status:** Major progress - 65 bytes → 17 bytes difference remaining

---

## Current State (Session 4 Update)

### ✅ What's Fixed

1. **Data Type Encoding Bug** - FIXED ✓
   - Changed from `dt[0], dt[0], dt[1]` to `dt[0], dt[1], dt[2]`
   - File: `lib/src/protocol/messages/fast_auth_message.dart:143-146`

2. **Complete Data Types List** - IMPLEMENTED ✓
   - Copied all 310 data types from node-oracledb
   - Source: `reference/node-oracledb/lib/thin/protocol/messages/dataType.js:76-399`
   - Target: `lib/src/transport/transport.dart:625-936`
   - Automated conversion via `convert_datatypes.cjs`

3. **Field Version Correction** - FIXED ✓
   - Changed from 24 (TNS_CCAP_FIELD_VERSION_MAX) to 13 (TNS_CCAP_FIELD_VERSION_19_1_EXT_1)
   - File: `lib/src/protocol/messages/fast_auth_message.dart:89-90`
   - Per node-oracledb: FAST_AUTH uses field version 13

4. **Trailing Zero Trimming** - IMPLEMENTED ✓
   - Added `_trimTrailingZeros()` method
   - File: `lib/src/protocol/messages/fast_auth_message.dart:238-244`
   - Trims compile/runtime caps before writing

### ⚠️ Remaining Issue

**Data Types List Content Mismatch: 17-byte difference**

- **Our packet:** 2797 bytes
- **Node packet:** 2780 bytes
- **Difference:** 17 bytes (reduced from 65!)
- **Progress:** 74% reduction in byte difference

**Analysis:**
- Byte 0-1920: ✓ Matches node-oracledb (except driver name)
- Byte 1921+: ✗ Data types section differs
- Likely cause: Missing, extra, or reordered data type entries

**Oracle Response:**
- Before fixes: MARKER packet (type 12) - protocol validation
- After fixes: Socket closed - Oracle terminates connection
- Interpretation: Closer to correct protocol, but still rejected

### 📂 Files Modified (Session 4)

**Core Implementation:**
- `lib/src/protocol/messages/fast_auth_message.dart`
  - Lines 89-90: Field version = 13
  - Lines 134-141: Trim compile/runtime caps
  - Lines 143-146: Fixed data type encoding
  - Lines 238-244: Added _trimTrailingZeros()

- `lib/src/transport/transport.dart`
  - Lines 625-936: Replaced with 310 data types from node
  - Lines 437-441: Added debug output (save bytes to file)

**Tools Created:**
- `convert_datatypes.cjs` - Automated JS→Dart data types conversion
- `datatypes_dart.txt` - Generated 310-entry list
- `compare_bytes.dart` - Byte comparison utility
- `dart_fast_auth.bin` - Our FAST_AUTH packet (for debugging)
- `node_fast_auth.bin` - Node's FAST_AUTH packet (reference)

---

## Next Steps to Complete

### Step 1: Identify Data Types Discrepancy (30-60 min)

**Goal:** Find which data types differ between byte 1921-2797

**Approach:**
```bash
# Extract data types section from both files
dd if=node_fast_auth.bin of=node_datatypes.bin bs=1 skip=1920
dd if=dart_fast_auth.bin of=dart_datatypes.bin bs=1 skip=1920

# Compare entry by entry (8 bytes each)
hexdump -v -e '8/1 "%02x " "\n"' node_datatypes.bin > node_dt.txt
hexdump -v -e '8/1 "%02x " "\n"' dart_datatypes.bin > dart_dt.txt
diff node_dt.txt dart_dt.txt | head -50
```

**Expected findings:**
- Missing entries (node has, we don't)
- Extra entries (we have, node doesn't)
- Wrong order (same entries, different sequence)

### Step 2: Fix Data Types List (15-30 min)

Once discrepancy identified:
1. Manually adjust `_dataTypes` in `transport.dart:625-936`
2. OR re-run conversion script with corrections
3. Verify byte count matches exactly

### Step 3: Test (5 min)

```bash
RUN_INTEGRATION_TESTS=true dart test test/integration/minimal_auth_test.dart
```

**Success criteria:**
- Packet size: 2780 bytes (matches node exactly)
- Oracle response: AUTH_PHASE_ONE response (not connection close)
- Response length: > 0 bytes

### Step 4: Complete Authentication (2-4 hours)

If Step 3 succeeds:
1. **Task 6.2-6.4:** Analyze AUTH_PHASE_ONE response
2. **Task 7:** Implement/validate AUTH_PHASE_TWO
3. **Task 8:** Integration test validation
4. **Task 9:** Documentation updates
5. **Task 10:** Finalize (analyze, format, sprint status)

---

## Technical Discoveries (Session 4)

1. **Field Version Matters**
   - Node uses field version 13 for FAST_AUTH (not 24)
   - Reference: `fastAuth.js:56` sets `TNS_CCAP_FIELD_VERSION_19_1_EXT_1`
   - Then restores to MAX after embedding data types

2. **Trailing Zeros Must Be Trimmed**
   - Node's `writeBytesWithLength()` trims trailing zeros
   - Compile caps: 53 bytes allocated, but only non-zero bytes sent
   - Our implementation now matches this behavior

3. **Data Type Encoding Format**
   - Each entry: 8 bytes = `[dt, convDt, typeRep, padding]`
   - dt[0] = dataType, dt[1] = convDataType, dt[2] = typeRep
   - All fields are uint16BE (big-endian)

4. **Oracle Validation is Strict**
   - 65-byte difference → MARKER packet (validation error)
   - 17-byte difference → Socket close (protocol error)
   - Even small discrepancies cause rejection

---

## Quick Reference

### File Locations

**Implementation:**
- Constants: [constants.dart:168](../lib/src/protocol/constants.dart#L168) - ttcMsgTypeFastAuth = 34
- FAST_AUTH: [fast_auth_message.dart](../lib/src/protocol/messages/fast_auth_message.dart)
- Transport: [transport.dart:413](../lib/src/transport/transport.dart#L413) - sendFastAuth()
- Data types: [transport.dart:625-936](../lib/src/transport/transport.dart#L625) - 310 entries

**Tests:**
- Minimal test: [minimal_auth_test.dart:105](../test/integration/minimal_auth_test.dart#L105)

**Reference:**
- Node FAST_AUTH: `reference/node-oracledb/lib/thin/protocol/messages/fastAuth.js`
- Node data types: `reference/node-oracledb/lib/thin/protocol/messages/dataType.js:76-399`
- Node constants: `reference/node-oracledb/lib/thin/protocol/constants.js`

**Documentation:**
- Story file: [1-4-fix-authentication-protocol-debugging.md](./sprint-artifacts/1-4-fix-authentication-protocol-debugging.md)
- Sprint status: [sprint-status.yaml:53](./sprint-artifacts/sprint-status.yaml#L53)

### Debug Commands

```bash
# Generate reference packet
node compare_fast_auth_bytes.cjs

# Test and capture our packet
RUN_INTEGRATION_TESTS=true dart test test/integration/minimal_auth_test.dart

# Compare packets
wc -c node_fast_auth.bin dart_fast_auth.bin
hexdump -C node_fast_auth.bin | head -20
hexdump -C dart_fast_auth.bin | head -20

# Find differences
cmp -l node_fast_auth.bin dart_fast_auth.bin | head -50

# Check Oracle container
docker ps | grep oracle
```

---

## Session Summary

**Time Spent:** ~2.5 hours
**Progress:** 74% reduction in byte difference (65 → 17 bytes)
**Commits:** None (work in progress)

**Achievements:**
- ✅ Fixed data type encoding bug
- ✅ Imported all 310 data types from node
- ✅ Corrected field version to 13
- ✅ Implemented trailing zero trimming
- ✅ Created automated conversion tooling

**Remaining Work:** 17-byte discrepancy in data types section (bytes 1921+)

**Recommendation:** Fresh debugging session to systematically compare data types lists entry-by-entry. The infrastructure is now correct; just need to find the specific entries that differ.
