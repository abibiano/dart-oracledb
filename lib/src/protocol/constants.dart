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

/// UROWID data type.
const int oraTypeURowid = 104;

/// CLOB data type.
const int oraTypeClob = 112;

/// BLOB data type.
const int oraTypeBlob = 113;

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

/// Inconsistent datatypes.
const int oraDataTypeNotSupported = 932;

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

/// Bit vector message type (sparse row selection).
const int ttcMsgTypeBitVector = 21;

/// Server-side piggyback (transactional updates, LTXID, etc.).
const int ttcMsgTypeServerSidePiggyback = 23;

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

/// Oracle wire charset UTF-8 (AL32UTF8).
const int ttcCharsetUtf8 = 873;

// ============================================================================
// TTC Length / Limits
// ============================================================================

/// Long length indicator for chunked encoding.
const int ttcLongLengthIndicator = 0xFE;

/// Null length indicator.
const int ttcNullLengthIndicator = 0xFF;

/// Maximum LONG / LONG RAW length.
const int ttcMaxLongLength = 0x7fffffff;

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
