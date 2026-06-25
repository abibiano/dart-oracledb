/// TTC (Two-Task Common) protocol constants for Oracle wire protocol.
///
/// TTC is Oracle's application-level protocol that runs on top of TNS.
/// These constants define function codes, data type indicators, capability
/// flags, and error codes used in TTC message handling.
library;

// ============================================================================
// TTC Function Codes
// ============================================================================

/// Protocol negotiation function code.
const int ttcProtocol = 1;

/// Data type negotiation function code.
const int ttcDataTypes = 2;

/// Authentication phase 1 function code.
const int ttcAuthPhaseOne = 0x76; // 118

/// Authentication phase 2 function code.
const int ttcAuthPhaseTwo = 0x73; // 115

/// Close connection function code.
const int ttcClose = 0x09; // 9

/// Legacy execute opcode marker; for TTC RPC, use [ttcFuncExecute].
const int ttcExecute = 0x03; // 3

/// Legacy fetch opcode marker; for TTC RPC, use [ttcFuncFetch].
const int ttcFetch = 0x05; // 5

/// TTC RPC function code: full execute (OALL8).
const int ttcFuncExecute = 94;

/// TTC RPC function code: fetch more rows.
const int ttcFuncFetch = 5;

/// TTC RPC function code: re-execute (cursor cached).
const int ttcFuncReExecute = 4;

/// TTC RPC function code: re-execute and fetch (cursor cached).
const int ttcFuncReExecuteAndFetch = 78;

/// TTC RPC function code: commit.
const int ttcFuncCommit = 14;

/// TTC RPC function code: rollback.
const int ttcFuncRollback = 15;

/// TTC RPC function code: close cursors.
const int ttcFuncCloseCursors = 105;

/// Commit transaction function code.
const int ttcCommit = 0x0E; // 14

/// Rollback transaction function code.
const int ttcRollback = 0x0F; // 15

/// Connection ping function code.
const int ttcPing = 0x93; // 147

/// LOB operation function code.
const int ttcLobOp = 0x60; // 96

// ============================================================================
// LOB Operation Codes (TNS_LOB_OP_* in node-oracledb constants.js)
// ============================================================================

/// LOB operation: get LOB length.
const int tnsLobOpGetLength = 0x0001;

/// LOB operation: read data from a LOB.
const int tnsLobOpRead = 0x0002;

/// LOB operation: write data to a LOB.
const int tnsLobOpWrite = 0x0040;

/// LOB operation: get the server-side chunk size.
const int tnsLobOpGetChunkSize = 0x4000;

/// LOB operation: create a temporary LOB.
const int tnsLobOpCreateTemp = 0x0110;

/// LOB operation: free a temporary LOB.
const int tnsLobOpFreeTemp = 0x0111;

/// LOB operation modifier: the operation applies to an array of locators
/// (used with [tnsLobOpFreeTemp] in the free-temp-LOBs piggyback).
const int tnsLobOpArray = 0x80000;

/// Session duration indicator for temporary LOB creation
/// (TNS_DURATION_SESSION).
const int tnsDurationSession = 10;

/// Bind/define metadata cont-flag requesting LOB prefetch metadata
/// (length + chunk size sent inline with the locator).
const int tnsLobPrefetchFlag = 0x2000000;

/// Locator byte offset of flag byte 3 (TNS_LOB_LOC_OFFSET_FLAG_3).
const int tnsLobLocOffsetFlag3 = 6;

/// Flag-3 bit: the locator uses a variable-length (NCHAR) character set
/// (TNS_LOB_LOC_FLAGS_VAR_LENGTH_CHARSET).
const int tnsLobLocFlagsVarLengthCharset = 0x80;

/// Size in bytes of a fresh (all-zero) temporary LOB locator buffer.
const int tnsLobLocatorBufferSize = 40;

/// Maximum native JSON (OSON) payload size declared in bind metadata
/// (TNS_JSON_MAX_LENGTH — 32 MB).
const int tnsJsonMaxLength = 32 * 1024 * 1024;

/// QLocator version written in value-based abstract LOB locators
/// (TNS_LOB_QLOCATOR_VERSION).
const int tnsLobQLocatorVersion = 4;

/// Locator flag byte 1: BLOB storage (TNS_LOB_LOC_FLAGS_BLOB).
const int tnsLobLocFlagsBlob = 0x01;

/// Locator flag byte 1: value-based locator (TNS_LOB_LOC_FLAGS_VALUE_BASED).
const int tnsLobLocFlagsValueBased = 0x20;

/// Locator flag byte 1: abstract LOB (TNS_LOB_LOC_FLAGS_ABSTRACT) — used for
/// JSON/VECTOR payloads that travel inline rather than via LOB operations.
const int tnsLobLocFlagsAbstract = 0x40;

/// Locator flag byte 2: initialized (TNS_LOB_LOC_FLAGS_INIT).
const int tnsLobLocFlagsInit = 0x08;

// ============================================================================
// Oracle Data Type Indicators
// ============================================================================

/// VARCHAR2 data type.
const int oraTypeVarchar = 1;

/// NUMBER data type.
const int oraTypeNumber = 2;

/// INTEGER data type (mapped to NUMBER).
const int oraTypeInteger = 3;

/// FLOAT data type.
const int oraTypeFloat = 4;

/// STRING/CHAR data type.
const int oraTypeString = 5;

/// VARNUM data type.
const int oraTypeVarnum = 6;

/// LONG data type.
const int oraTypeLong = 8;

/// VARCHAR2 data type (alternate).
const int oraTypeVarchar2 = 9;

/// ROWID data type.
const int oraTypeRowid = 11;

/// DATE data type.
const int oraTypeDate = 12;

/// RAW data type.
const int oraTypeRaw = 23;

/// LONG RAW data type.
const int oraTypeLongRaw = 24;

/// CHAR data type (fixed-length character).
const int oraTypeChar = 96;

/// REF CURSOR / SYS_REFCURSOR data type. Returned as a lazy [OracleResultSet]
/// for OUT binds. Buffer-size factor = 4 (node-oracledb DB_TYPE_CURSOR).
const int oraTypeCursor = 102;

/// UROWID data type.
const int oraTypeURowid = 104;

/// CLOB data type.
const int oraTypeClob = 112;

/// BLOB data type.
const int oraTypeBlob = 113;

/// BFILE data type.
const int oraTypeBfile = 114;

/// JSON data type (Oracle 21c+).
const int oraTypeJson = 119;

/// TIMESTAMP data type.
const int oraTypeTimestamp = 180;

/// TIMESTAMP WITH TIME ZONE data type.
const int oraTypeTimestampTz = 181;

/// TIMESTAMP WITH LOCAL TIME ZONE data type.
const int oraTypeTimestampLtz = 231;

// ============================================================================
// Protocol Capability Flags
// ============================================================================

/// End of call status capability flag.
const int capabilityEndOfCallStatus = 0x01;

/// OCI8 LOB capability flag.
const int capabilityOci8Lob = 0x02;

/// Session state capability flag.
const int capabilitySessionState = 0x04;

// ============================================================================
// Protocol Error Codes
// ============================================================================

/// TNS:packet writer failure - malformed packet.
const int oraMalformedPacket = 12571;

/// TNS:data truncation - protocol violation.
const int oraProtocolViolation = 12585;

/// Unsupported network datatype.
const int oraUnsupportedType = 3115;

/// Inconsistent datatypes (ORA-00932). Also reported by the server when a
/// cached SELECT cursor's column types changed under it (e.g. cross-session
/// DDL); see [oraVarNotInSelectList] for the re-execute retry contract.
/// Mirrors node-oracledb `TNS_ERR_INCONSISTENT_DATA_TYPES`.
const int oraDataTypeNotSupported = 932;

/// Variable not in select list (ORA-01007). A cached SELECT cursor whose
/// result shape changed under it (e.g. a column dropped by cross-session DDL)
/// reports this on re-execute. Together with [oraDataTypeNotSupported] these
/// are the two "describe-mismatch" codes on which node-oracledb
/// (`withData.js processErrorInfo`) transparently clears the cursor and
/// re-executes the statement ONCE, for queries only. Integrity/constraint
/// violations (ORA-00001 etc.) carry different codes and so never match this
/// gate — re-running them would change nothing.
const int oraVarNotInSelectList = 1007;

// ============================================================================
// TTC Message Types
// ============================================================================

/// Protocol message type.
const int ttcMsgTypeProtocol = 1;

/// Data types message type.
const int ttcMsgTypeDataTypes = 2;

/// Function call message type.
const int ttcMsgTypeFunction = 3;

/// Error message type.
const int ttcMsgTypeError = 4;

/// Row header message type.
const int ttcMsgTypeRowHeader = 6;

/// Row data message type.
const int ttcMsgTypeRowData = 7;

/// Parameter/return data message type.
const int ttcMsgTypeParameter = 8;

/// Status message type.
const int ttcMsgTypeStatus = 9;

/// Warning message type.
const int ttcMsgTypeWarning = 15;

/// Fast authentication message type (Oracle 23ai optimization).
/// Combines protocol negotiation, data types, and AUTH_PHASE_ONE in a single message.
const int ttcMsgTypeFastAuth = 34;

/// Row data describe-info message type (column metadata).
const int ttcMsgTypeDescribeInfo = 16;

/// IO vector message type (used for OUT bind directions).
const int ttcMsgTypeIoVector = 11;

/// Piggyback message type (client → server side metadata).
const int ttcMsgTypePiggyback = 17;

/// LOB data message type (payload of a LOB read; also written before LOB
/// data in a LOB write request).
const int ttcMsgTypeLobData = 14;

/// Bit vector message type (sparse row selection).
const int ttcMsgTypeBitVector = 21;

/// Server-side piggyback (transactional updates, LTXID, etc.).
const int ttcMsgTypeServerSidePiggyback = 23;

/// Implicit result set message (PL/SQL `DBMS_SQL.RETURN_RESULT`).
///
/// Carries one or more server cursors returned implicitly by a PL/SQL block,
/// each as an embedded cursor describe block plus a UB2 server cursor id
/// (node-oracledb `TNS_MSG_TYPE_IMPLICIT_RESULTSET`).
const int ttcMsgTypeImplicitResultSet = 27;

/// End of request marker (response complete).
const int ttcMsgTypeEndOfRequest = 29;

// ============================================================================
// TTC Execute Option Flags (al8i4 / dmlOptions)
// ============================================================================

/// Parse SQL.
const int ttcExecOptionParse = 0x01;

/// Bind parameters present.
const int ttcExecOptionBind = 0x08;

/// Define query columns explicitly (re-execute with describe).
const int ttcExecOptionDefine = 0x10;

/// Execute the SQL.
const int ttcExecOptionExecute = 0x20;

/// Fetch rows in the same round trip.
const int ttcExecOptionFetch = 0x40;

/// Auto-commit.
const int ttcExecOptionCommit = 0x100;

/// Describe query without executing.
const int ttcExecOptionDescribe = 0x20000;

/// SQL is not PL/SQL (used in the `options` field of EXECUTE request).
const int ttcExecOptionNotPlSql = 0x8000;

/// Implicit result set (used in the `dmlOptions` field of EXECUTE request —
/// different field from [ttcExecOptionNotPlSql] despite sharing the same value).
const int ttcExecOptionImplicitResultset = 0x8000;

/// PL/SQL bind variables.
const int ttcExecOptionPlSqlBind = 0x400;

// ============================================================================
// TTC Bind Directions (IO_VECTOR direction byte)
// ============================================================================

/// IN bind — value flows client → server only.
const int tnsBindDirInput = 32;

/// OUT bind — value flows server → client (function/procedure return values).
const int tnsBindDirOutput = 16;

/// IN OUT bind — value flows both directions.
const int tnsBindDirInputOutput = 48;

// ============================================================================
// TTC Bind Flags
// ============================================================================

/// Bind values include null indicator bytes.
const int ttcBindUseIndicators = 0x0001;

/// Bind is an array.
const int ttcBindArray = 0x0040;

// ============================================================================
// TTC Char Set Form
// ============================================================================

/// Implicit charset (database character set).
const int ttcCsfrmImplicit = 1;

/// NCHAR charset.
const int ttcCsfrmNChar = 2;

/// Primary client character set advertised on the wire: AL32UTF8/UTF-8.
///
/// The thin driver always negotiates this single primary client charset for
/// character data and relies on the Oracle server to convert to/from its own
/// database character set (the node-oracledb thin model). This is independent
/// of the detected [OracleCharsetInfo.databaseCharset], which is diagnostic
/// only and must never select a client-side codec. Both the DataTypes
/// negotiation charset fields and the AUTH_PHASE_TWO `SESSION_CLIENT_CHARSET`
/// session attribute are written from this constant.
///
/// The national character set form ([ttcCsfrmNChar]) — not a distinct wire
/// charset id — is what marks `NCHAR`/`NVARCHAR2`/`NCLOB` values; both
/// negotiation slots and every column charset field stay [ttcCharsetUtf8].
/// See [ttcCharsetAl16Utf16] and [ttcCsfrmNChar].
const int ttcCharsetUtf8 = 873;

/// Wire id for Oracle's `AL16UTF16` national character set (UTF-16), the only
/// national charset the thin driver round-trips for `NCHAR`/`NVARCHAR2`/
/// `NCLOB`. Equals node-oracledb's `TNS_CHARSET_UTF16`.
///
/// IMPORTANT — this id is deliberately NOT written into the DataTypes
/// negotiation message or per-column bind/define metadata. node-oracledb
/// (`dataType.js`, `withData.js writeColumnMetadata`) advertises
/// [ttcCharsetUtf8] in *both* the primary and national charset slots and in
/// every character column's charset field; a column/bind is marked national
/// purely by its [ttcCsfrmNChar] character set form byte, and the value itself
/// then travels as UTF-16BE. Writing `2000` into the DataTypes national slot
/// instead corrupts the FAST_AUTH handshake (the server returns a malformed
/// AUTH_SESSKEY). This constant therefore documents the national charset id
/// the driver assumes — the value a supported server reports for
/// `NLS_NCHAR_CHARACTERSET` — while the actual fail-loud guard against an
/// unsupported national charset lives in
/// [OracleCharsetInfo.supportsNationalCharacterSet], detected at connect time.
const int ttcCharsetAl16Utf16 = 2000;

// ============================================================================
// TTC Length / Limits
// ============================================================================

/// Long length indicator for chunked encoding.
const int ttcLongLengthIndicator = 0xFE;

/// Null length indicator.
const int ttcNullLengthIndicator = 0xFF;

/// Maximum LONG / LONG RAW length.
const int ttcMaxLongLength = 0x7fffffff;

/// Maximum byte size of a short (non-long) string/RAW bind. Values declared
/// beyond this use Oracle's long-data ordering for SQL, and are converted to
/// temporary CLOBs for PL/SQL (node-oracledb `caps.maxStringSize` with the
/// 32K runtime capability this driver always requests).
const int ttcMaxVarcharBindBytes = 32767;

/// Maximum byte size of a short (non-long) RAW bind. PL/SQL byte binds
/// beyond this limit are converted to temporary BLOBs (node-oracledb retypes
/// PL/SQL RAW binds with maxSize > 32767 to DB_TYPE_BLOB the same way).
/// Currently equal to [ttcMaxVarcharBindBytes], but kept as a separate
/// constant so either limit can be retuned without silently dragging the
/// other along. (The SQL long-bind classification in execute_message.dart
/// deliberately keeps the shared VARCHAR threshold — node-oracledb parity.)
const int ttcMaxRawBindBytes = 32767;

/// CCAP field version index in compile capabilities array.
const int ttcCcapFieldVersionIndex = 7;

/// CCAP field version threshold for writing token numbers (UB8).
const int ttcCcapFieldVersion23_1Ext1 = 18;

/// CCAP field version threshold for Oracle 12.2 (some fields).
const int ttcCcapFieldVersion12_2 = 8;

/// CCAP field version threshold for Oracle 12.2 ext1 (chunk ids).
const int ttcCcapFieldVersionExt1 = 9;

/// CCAP field version threshold for Oracle 20.1 (sql type + checksum in
/// error response). Value 14 = TNS_CCAP_FIELD_VERSION_20_1 in node-oracledb
/// `constants.js`. The previous value `10` was actually 18_1 and over-fired
/// on 18c/19c/21c, reading 8 stale bytes from the buffer.
const int ttcCcapFieldVersion20_1 = 14;

/// CCAP field version threshold for Oracle 23.1 — domain schema and domain
/// name added to column metadata.
const int ttcCcapFieldVersion23_1 = 17;

/// CCAP field version threshold for Oracle 23.1 ext 3 — column annotations.
const int ttcCcapFieldVersion23_1Ext3 = 20;

/// CCAP field version threshold for Oracle 23.4 vector fields.
/// Value 24 = TNS_CCAP_FIELD_VERSION_MAX in node-oracledb constants.js.
/// Servers older than 23.4 negotiate a lower field version; use this
/// threshold to gate the three vector-related fields in column metadata.
const int ttcCcapFieldVersion23_4 = 24;

// ============================================================================
// TTC Authentication Mode Flags
// ============================================================================

/// Normal logon mode.
const int ttcAuthModeLogon = 0x00000001;

/// Change password mode.
const int ttcAuthModeChangePassword = 0x00000002;

/// SYSDBA mode.
const int ttcAuthModeSysdba = 0x00000020;

/// SYSOPER mode.
const int ttcAuthModeSysoper = 0x00000040;

/// Authentication with password.
const int ttcAuthModeWithPassword = 0x00000100;

// ============================================================================
// TTC Verifier Types
// ============================================================================

/// SHA-1 (11g) verifier type 1.
const int ttcVerifierType11g1 = 0xb152;

/// SHA-1 (11g) verifier type 2.
const int ttcVerifierType11g2 = 0x1b25;

/// SHA-512 (12c+) verifier type.
const int ttcVerifierType12c = 0x4815;

// ============================================================================
// TTC Data Flags
// ============================================================================

/// No rows affected flag.
const int ttcDataFlagNoRowsAffected = 0x01;

/// Continue flag.
const int ttcDataFlagContinue = 0x02;

/// End of fetch flag.
const int ttcDataFlagEof = 0x04;
