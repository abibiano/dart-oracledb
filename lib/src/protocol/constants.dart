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

/// Execute statement function code.
const int ttcExecute = 0x03; // 3

/// Fetch rows function code.
const int ttcFetch = 0x05; // 5

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
