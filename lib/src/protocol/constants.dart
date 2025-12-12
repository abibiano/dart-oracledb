/// Protocol constants for Oracle Database TTC/TNS wire protocol.
///
/// Ported from node-oracledb lib/thin/protocol/constants.js
library;

import 'dart:typed_data';

// =============================================================================
// Bind Constants
// =============================================================================

/// Input bind direction
const bindIn = 1;

/// Input/output bind direction
const bindInOut = 2;

/// Output bind direction
const bindOut = 3;

/// Character set form: implicit (database charset)
const csfrmImplicit = 1;

/// Character set form: NCHAR charset
const csfrmNchar = 2;

/// DRCP session purity: default
const purityDefault = 0;

/// DRCP session purity: new session
const purityNew = 1;

/// DRCP session purity: reuse session
const puritySelf = 2;

// =============================================================================
// Privileged Modes
// =============================================================================

const sysdba = 2;
const sysoper = 4;
const sysasm = 32768;
const sysbackup = 131072;
const sysdg = 262144;
const syskm = 524288;
const sysrac = 1048576;

// =============================================================================
// Authentication Modes
// =============================================================================

const authModeDefault = 0;
const authModePrelim = 0x00000008;
const authModeSysasm = 0x00008000;
const authModeSysbkp = 0x00020000;
const authModeSysdba = 0x00000002;
const authModeSysdgd = 0x00040000;
const authModeSyskmt = 0x00080000;
const authModeSysoper = 0x00000004;
const authModeSysrac = 0x00100000;

// TTC authentication modes
const tnsAuthModeLogon = 0x00000001;
const tnsAuthModeChangePassword = 0x00000002;
const tnsAuthModeSysdba = 0x00000020;
const tnsAuthModeSysoper = 0x00000040;
const tnsAuthModePrelim = 0x00000080;
const tnsAuthModeWithPassword = 0x00000100;
const tnsAuthModeSysasm = 0x00400000;
const tnsAuthModeSysbkp = 0x01000000;
const tnsAuthModeSysdgd = 0x02000000;
const tnsAuthModeSyskmt = 0x04000000;
const tnsAuthModeSysrac = 0x08000000;
const tnsAuthModeIamToken = 0x20000000;

// =============================================================================
// TNS Packet Types
// =============================================================================

const tnsPacketTypeConnect = 1;
const tnsPacketTypeAccept = 2;
const tnsPacketTypeRefuse = 4;
const tnsPacketTypeRedirect = 5;
const tnsPacketTypeData = 6;
const tnsPacketTypeResend = 11;
const tnsPacketTypeMarker = 12;
const tnsPacketTypeControl = 14;

// =============================================================================
// TNS Data Types
// =============================================================================

const tnsDataTypeDefault = 0;
const tnsDataTypeVarchar = 1;
const tnsDataTypeNumber = 2;
const tnsDataTypeBinaryInteger = 3;
const tnsDataTypeFloat = 4;
const tnsDataTypeStr = 5;
const tnsDataTypeVnu = 6;
const tnsDataTypePdn = 7;
const tnsDataTypeLong = 8;
const tnsDataTypeVcs = 9;
const tnsDataTypeTiddef = 10;
const tnsDataTypeRowid = 11;
const tnsDataTypeDate = 12;
const tnsDataTypeVbi = 15;
const tnsDataTypeRaw = 23;
const tnsDataTypeLongRaw = 24;
const tnsDataTypeUb2 = 25;
const tnsDataTypeUb4 = 26;
const tnsDataTypeSb1 = 27;
const tnsDataTypeSb2 = 28;
const tnsDataTypeSb4 = 29;
const tnsDataTypeSword = 30;
const tnsDataTypeUword = 31;
const tnsDataTypePtrb = 32;
const tnsDataTypePtrw = 33;
const tnsDataTypeOer8 = 34 + 256;
const tnsDataTypeFun = 35 + 256;
const tnsDataTypeAua = 36 + 256;
const tnsDataTypeRxh7 = 37 + 256;
const tnsDataTypeNa6 = 38 + 256;
const tnsDataTypeOac9 = 39;
const tnsDataTypeAms = 40;
const tnsDataTypeBrn = 41;
const tnsDataTypeBrp = 42 + 256;
const tnsDataTypeBrv = 43 + 256;
const tnsDataTypeKva = 44 + 256;
const tnsDataTypeCls = 45 + 256;
const tnsDataTypeCui = 46 + 256;
const tnsDataTypeDfn = 47 + 256;
const tnsDataTypeDqr = 48 + 256;
const tnsDataTypeDsc = 49 + 256;
const tnsDataTypeExe = 50 + 256;
const tnsDataTypeFch = 51 + 256;
const tnsDataTypeGbv = 52 + 256;
const tnsDataTypeGem = 53 + 256;
const tnsDataTypeGiv = 54 + 256;
const tnsDataTypeOkg = 55 + 256;
const tnsDataTypeHmi = 56 + 256;
const tnsDataTypeIno = 57 + 256;
const tnsDataTypeLnf = 59 + 256;
const tnsDataTypeOnt = 60 + 256;
const tnsDataTypeOpe = 61 + 256;
const tnsDataTypeOsq = 62 + 256;
const tnsDataTypeSfe = 63 + 256;
const tnsDataTypeSpf = 64 + 256;
const tnsDataTypeVsn = 65 + 256;
const tnsDataTypeUd7 = 66 + 256;
const tnsDataTypeDsa = 67 + 256;
const tnsDataTypeUin = 68;
const tnsDataTypePin = 71 + 256;
const tnsDataTypePfn = 72 + 256;
const tnsDataTypePpt = 73 + 256;
const tnsDataTypeSto = 75 + 256;
const tnsDataTypeArc = 77 + 256;
const tnsDataTypeMrs = 78 + 256;
const tnsDataTypeMrt = 79 + 256;
const tnsDataTypeMrg = 80 + 256;
const tnsDataTypeMrr = 81 + 256;
const tnsDataTypeMrc = 82 + 256;
const tnsDataTypeVer = 83 + 256;
const tnsDataTypeLon2 = 84 + 256;
const tnsDataTypeIno2 = 85 + 256;
const tnsDataTypeAll = 86 + 256;
const tnsDataTypeUdb = 87 + 256;
const tnsDataTypeAqi = 88 + 256;
const tnsDataTypeUlb = 89 + 256;
const tnsDataTypeUld = 90 + 256;
const tnsDataTypeSls = 91;
const tnsDataTypeSid = 92 + 256;
const tnsDataTypeNa7 = 93 + 256;
const tnsDataTypeLvc = 94;
const tnsDataTypeLvb = 95;
const tnsDataTypeChar = 96;
const tnsDataTypeAvc = 97;
const tnsDataTypeAl7 = 98 + 256;
const tnsDataTypeK2rpc = 99 + 256;
const tnsDataTypeBinaryFloat = 100;
const tnsDataTypeBinaryDouble = 101;
const tnsDataTypeCursor = 102;
const tnsDataTypeRdd = 104;
const tnsDataTypeXdp = 103 + 256;
const tnsDataTypeOsl = 106;
const tnsDataTypeOko8 = 107 + 256;
const tnsDataTypeExtNamed = 108;
const tnsDataTypeIntNamed = 109;
const tnsDataTypeExtRef = 110;
const tnsDataTypeIntRef = 111;
const tnsDataTypeClob = 112;
const tnsDataTypeBlob = 113;
const tnsDataTypeBfile = 114;
const tnsDataTypeCfile = 115;
const tnsDataTypeRset = 116;
const tnsDataTypeCwd = 117;
const tnsDataTypeJson = 119;
const tnsDataTypeOac122 = 120;
const tnsDataTypeUd12 = 124 + 256;
const tnsDataTypeAl8 = 125 + 256;
const tnsDataTypeLfop = 126 + 256;
const tnsDataTypeVector = 127;
const tnsDataTypeFcrt = 127 + 256;
const tnsDataTypeDny = 128 + 256;
const tnsDataTypeOpr = 129 + 256;
const tnsDataTypePls = 130 + 256;
const tnsDataTypeXid = 131 + 256;
const tnsDataTypeTxn = 132 + 256;
const tnsDataTypeDcb = 133 + 256;
const tnsDataTypeCca = 134 + 256;
const tnsDataTypeWrn = 135 + 256;
const tnsDataTypeTlh = 137 + 256;
const tnsDataTypeToh = 138 + 256;
const tnsDataTypeFoi = 139 + 256;
const tnsDataTypeSid2 = 140 + 256;
const tnsDataTypeTch = 141 + 256;
const tnsDataTypePii = 142 + 256;
const tnsDataTypePfi = 143 + 256;
const tnsDataTypePpu = 144 + 256;
const tnsDataTypePte = 145 + 256;
const tnsDataTypeClv = 146;
const tnsDataTypeRxh8 = 148 + 256;
const tnsDataTypeN12 = 149 + 256;
const tnsDataTypeAuth = 150 + 256;
const tnsDataTypeKval = 151 + 256;
const tnsDataTypeDtr = 152;
const tnsDataTypeDun = 153;
const tnsDataTypeDop = 154;
const tnsDataTypeVst = 155;
const tnsDataTypeOdt = 156;
const tnsDataTypeFgi = 157 + 256;
const tnsDataTypeDsy = 158 + 256;
const tnsDataTypeDsyr8 = 159 + 256;
const tnsDataTypeDsyh8 = 160 + 256;
const tnsDataTypeDsyl = 161 + 256;
const tnsDataTypeDsyt8 = 162 + 256;
const tnsDataTypeDsyv8 = 163 + 256;
const tnsDataTypeDsyp = 164 + 256;
const tnsDataTypeDsyf = 165 + 256;
const tnsDataTypeDsyk = 166 + 256;
const tnsDataTypeDsyy = 167 + 256;
const tnsDataTypeDsyq = 168 + 256;
const tnsDataTypeDsyc = 169 + 256;
const tnsDataTypeDsya = 170 + 256;
const tnsDataTypeOt8 = 171 + 256;
const tnsDataTypeDol = 172;
const tnsDataTypeDsyty = 173 + 256;
const tnsDataTypeAqe = 174 + 256;
const tnsDataTypeKv = 175 + 256;
const tnsDataTypeAqd = 176 + 256;
const tnsDataTypeAq8 = 177 + 256;
const tnsDataTypeTime = 178;
const tnsDataTypeTimeTz = 179;
const tnsDataTypeTimestamp = 180;
const tnsDataTypeTimestampTz = 181;
const tnsDataTypeIntervalYm = 182;
const tnsDataTypeIntervalDs = 183;
const tnsDataTypeEdate = 184;
const tnsDataTypeEtime = 185;
const tnsDataTypeEttz = 186;
const tnsDataTypeEstamp = 187;
const tnsDataTypeEstz = 188;
const tnsDataTypeEiym = 189;
const tnsDataTypeEids = 190;
const tnsDataTypeRfs = 193 + 256;
const tnsDataTypeRxh10 = 194 + 256;
const tnsDataTypeDclob = 195;
const tnsDataTypeDblob = 196;
const tnsDataTypeDbfile = 197;
const tnsDataTypeDjson = 198;
const tnsDataTypeKpn = 198 + 256;
const tnsDataTypeKpdnr = 199 + 256;
const tnsDataTypeDsyd = 200 + 256;
const tnsDataTypeDsys = 201 + 256;
const tnsDataTypeDsyr = 202 + 256;
const tnsDataTypeDsyh = 203 + 256;
const tnsDataTypeDsyt = 204 + 256;
const tnsDataTypeDsyv = 205 + 256;
const tnsDataTypeAqm = 206 + 256;
const tnsDataTypeOer11 = 207 + 256;
const tnsDataTypeUrowid = 208;
const tnsDataTypeAql = 210 + 256;
const tnsDataTypeOtc = 211 + 256;
const tnsDataTypeKfno = 212 + 256;
const tnsDataTypeKfnp = 213 + 256;
const tnsDataTypeKgt8 = 214 + 256;
const tnsDataTypeRasb4 = 215 + 256;
const tnsDataTypeRaub2 = 216 + 256;
const tnsDataTypeRaub1 = 217 + 256;
const tnsDataTypeRatxt = 218 + 256;
const tnsDataTypeRssb4 = 219 + 256;
const tnsDataTypeRsub2 = 220 + 256;
const tnsDataTypeRsub1 = 221 + 256;
const tnsDataTypeRstxt = 222 + 256;
const tnsDataTypeRidl = 223 + 256;
const tnsDataTypeGlrdd = 224 + 256;
const tnsDataTypeGlrdg = 225 + 256;
const tnsDataTypeGlrdc = 226 + 256;
const tnsDataTypeOko = 227 + 256;
const tnsDataTypeDpp = 228 + 256;
const tnsDataTypeDpls = 229 + 256;
const tnsDataTypeDpmop = 230 + 256;
const tnsDataTypeTimestampLtz = 231;
const tnsDataTypeEsitz = 232;
const tnsDataTypeUb8 = 233;
const tnsDataTypeStat = 234 + 256;
const tnsDataTypeRfx = 235 + 256;
const tnsDataTypeFal = 236 + 256;
const tnsDataTypeCkv = 237 + 256;
const tnsDataTypeDrcx = 238 + 256;
const tnsDataTypeKgh = 239 + 256;
const tnsDataTypeAqo = 240 + 256;
const tnsDataTypePnty = 241;
const tnsDataTypeOkgt = 242 + 256;
const tnsDataTypeKpfc = 243 + 256;
const tnsDataTypeFe2 = 244 + 256;
const tnsDataTypeSpfp = 245 + 256;
const tnsDataTypeDpuls = 246 + 256;
const tnsDataTypeBoolean = 252;
const tnsDataTypeAqa = 253 + 256;
const tnsDataTypeKpbf = 254 + 256;
const tnsDataTypeTsm = 513;
const tnsDataTypeMss = 514;
const tnsDataTypeKpc = 516;
const tnsDataTypeCrs = 517;
const tnsDataTypeKks = 518;
const tnsDataTypeKsp = 519;
const tnsDataTypeKsptop = 520;
const tnsDataTypeKspval = 521;
const tnsDataTypePss = 522;
const tnsDataTypeNls = 523;
const tnsDataTypeAls = 524;
const tnsDataTypeKsdevtval = 525;
const tnsDataTypeKsdevttop = 526;
const tnsDataTypeKpspp = 527;
const tnsDataTypeKol = 528;
const tnsDataTypeLst = 529;
const tnsDataTypeAcx = 530;
const tnsDataTypeScs = 531;
const tnsDataTypeRxh = 532;
const tnsDataTypeKpdns = 533;
const tnsDataTypeKpdcn = 534;
const tnsDataTypeKpnns = 535;
const tnsDataTypeKpncn = 536;
const tnsDataTypeKps = 537;
const tnsDataTypeApinf = 538;
const tnsDataTypeTen = 539;
const tnsDataTypeXsscs = 540;
const tnsDataTypeXssso = 541;
const tnsDataTypeXssao = 542;
const tnsDataTypeKsrpc = 543;
const tnsDataTypeKvl = 560;
const tnsDataTypeSessget = 563;
const tnsDataTypeSessrel = 564;
const tnsDataTypeXssdef = 565;
const tnsDataTypePdqcinv = 572;
const tnsDataTypePdqidc = 573;
const tnsDataTypeKpdqcsta = 574;
const tnsDataTypeKprs = 575;
const tnsDataTypeKpdqidc = 576;
const tnsDataTypeRtstrm = 578;
const tnsDataTypeSessret = 579;
const tnsDataTypeScn6 = 580;
const tnsDataTypeKecpa = 581;
const tnsDataTypeKecpp = 582;
const tnsDataTypeSxa = 583;
const tnsDataTypeKvarr = 584;
const tnsDataTypeKpngn = 585;
const tnsDataTypeXsnsop = 590;
const tnsDataTypeXsattr = 591;
const tnsDataTypeXsns = 592;
const tnsDataTypeTxt = 593;
const tnsDataTypeXssessns = 594;
const tnsDataTypeXsattop = 595;
const tnsDataTypeXscreop = 596;
const tnsDataTypeXsdetop = 597;
const tnsDataTypeXsdesop = 598;
const tnsDataTypeXssetsp = 599;
const tnsDataTypeXssidp = 600;
const tnsDataTypeXsprin = 601;
const tnsDataTypeXskvl = 602;
const tnsDataTypeXsssdef2 = 603;
const tnsDataTypeXsnsop2 = 604;
const tnsDataTypeXsns2 = 605;
const tnsDataTypeImplres = 611;
const tnsDataTypeOer19 = 612;
const tnsDataTypeUb1array = 613;
const tnsDataTypeSessstate = 614;
const tnsDataTypeAcReplay = 615;
const tnsDataTypeAcCont = 616;
const tnsDataTypeKpdnreq = 622;
const tnsDataTypeKpdnrnf = 623;
const tnsDataTypeKpngnc = 624;
const tnsDataTypeKpnri = 625;
const tnsDataTypeAqenq = 626;
const tnsDataTypeAqdeq = 627;
const tnsDataTypeAqjms = 628;
const tnsDataTypeKpdnrpay = 629;
const tnsDataTypeKpdnrack = 630;
const tnsDataTypeKpdnrmp = 631;
const tnsDataTypeKpdnrdq = 632;
const tnsDataTypeChunkinfo = 636;
const tnsDataTypeScn = 637;
const tnsDataTypeScn8 = 638;
const tnsDataTypeUd21 = 639;
const tnsDataTypeTnp = 640;
const tnsDataTypeOac = 646;
const tnsDataTypeSesssign = 647;
const tnsDataTypeOer = 652;
const tnsDataTypeUds = 663;

// =============================================================================
// Data Type Representations
// =============================================================================

const tnsTypeRepNative = 0;
const tnsTypeRepUniversal = 1;
const tnsTypeRepOracle = 10;

// =============================================================================
// TTC Message Types
// =============================================================================

const tnsMsgTypeProtocol = 1;
const tnsMsgTypeDataTypes = 2;
const tnsMsgTypeFunction = 3;
const tnsMsgTypeError = 4;
const tnsMsgTypeRowHeader = 6;
const tnsMsgTypeRowData = 7;
const tnsMsgTypeParameter = 8;
const tnsMsgTypeStatus = 9;
const tnsMsgTypeIoVector = 11;
const tnsMsgTypeLobData = 14;
const tnsMsgTypeWarning = 15;
const tnsMsgTypeDescribeInfo = 16;
const tnsMsgTypePiggyback = 17;
const tnsMsgTypeFlushOutBinds = 19;
const tnsMsgTypeBitVector = 21;
const tnsMsgTypeServerSidePiggyback = 23;
const tnsMsgTypeOnewayFn = 26;
const tnsMsgTypeImplicitResultset = 27;
const tnsMsgTypeRenegotiate = 28;
const tnsMsgTypeEndOfRequest = 29;
const tnsMsgTypeFastAuth = 34;

// =============================================================================
// Parameter Keyword Numbers
// =============================================================================

const tnsKeywordNumCurrentSchema = 168;
const tnsKeywordNumEdition = 172;
const tnsKeywordNumTransactionId = 201;

// =============================================================================
// Bind Flags and Directions
// =============================================================================

const tnsBindUseIndicators = 0x0001;
const tnsBindUseLength = 0x0002;
const tnsBindArray = 0x0040;

const tnsBindDirOutput = 16;
const tnsBindDirInput = 32;
const tnsBindDirInputOutput = 48;

// =============================================================================
// Execute Options
// =============================================================================

const tnsExecOptionParse = 0x01;
const tnsExecOptionBind = 0x08;
const tnsExecOptionDefine = 0x10;
const tnsExecOptionExecute = 0x20;
const tnsExecOptionFetch = 0x40;
const tnsExecOptionCommit = 0x100;
const tnsExecOptionCommitReexecute = 0x1;
const tnsExecOptionPlsqlBind = 0x400;
const tnsExecOptionDmlRowcounts = 0x4000;
const tnsExecOptionNotPlsql = 0x8000;
const tnsExecOptionImplicitResultset = 0x8000;
const tnsExecOptionDescribe = 0x20000;
const tnsExecOptionNoCompressedFetch = 0x40000;
const tnsExecOptionBatchErrors = 0x80000;
const tnsExecOptionNoImplRel = 0x200000;

// =============================================================================
// Server Side Piggyback Op Codes
// =============================================================================

const tnsServerPiggybackQueryCacheInvalidation = 1;
const tnsServerPiggybackOsPidMts = 2;
const tnsServerPiggybackTraceEvent = 3;
const tnsServerPiggybackSessRet = 4;
const tnsServerPiggybackSync = 5;
const tnsServerPiggybackLtxid = 7;
const tnsServerPiggybackAcReplayContext = 8;
const tnsServerPiggybackExtSync = 9;
const tnsServerPiggybackSessSignature = 10;

// =============================================================================
// Session Return Constants
// =============================================================================

const tnsSessgetSessionChanged = 4;

// =============================================================================
// LOB Operations
// =============================================================================

const tnsLobOpGetLength = 0x0001;
const tnsLobOpRead = 0x0002;
const tnsLobOpTrim = 0x0020;
const tnsLobOpWrite = 0x0040;
const tnsLobOpGetChunkSize = 0x4000;
const tnsLobOpCreateTemp = 0x0110;
const tnsLobOpFreeTemp = 0x0111;
const tnsLobOpOpen = 0x8000;
const tnsLobOpClose = 0x10000;
const tnsLobOpIsOpen = 0x11000;
const tnsLobOpArray = 0x80000;
const tnsLobOpFileOpen = 0x0100;
const tnsLobOpFileClose = 0x0200;
const tnsLobOpFileIsopen = 0x0400;
const tnsLobOpFileExists = 0x0800;

// =============================================================================
// LOB Locator Constants
// =============================================================================

const tnsLobLocOffsetFlag1 = 4;
const tnsLobLocOffsetFlag3 = 6;
const tnsLobLocOffsetFlag4 = 7;
const tnsLobQlocatorVersion = 4;
const tnsLobLocFixedOffset = 16;

// LOB locator flags (byte 1)
const tnsLobLocFlagsBlob = 0x01;
const tnsLobLocFlagsValueBased = 0x20;
const tnsLobLocFlagsAbstract = 0x40;

// LOB locator flags (byte 2)
const tnsLobLocFlagsInit = 0x08;

// LOB locator flags (byte 4)
const tnsLobLocFlagsTemp = 0x01;
const tnsLobLocFlagsVarLengthCharset = 0x80;

// Other LOB constants
const tnsLobOpenReadWrite = 2;
const tnsLobOpenReadOnly = 11;
const tnsLobPrefetchFlag = 0x2000000;

// =============================================================================
// JSON Constants
// =============================================================================

const tnsJsonMaxLength = 32 * 1024 * 1024;

// =============================================================================
// End-to-End Metrics
// =============================================================================

const tnsEndToEndAction = 0x0010;
const tnsEndToEndClientIdentifier = 0x0001;
const tnsEndToEndClientInfo = 0x0100;
const tnsEndToEndDbop = 0x0200;
const tnsEndToEndModule = 0x0008;

// =============================================================================
// Versions
// =============================================================================

const tnsVersionMinAccepted = 315;
const tnsVersionMinLargeSdu = 315;

// =============================================================================
// TTC Functions
// =============================================================================

const tnsFuncAuthPhaseOne = 118;
const tnsFuncAuthPhaseTwo = 115;
const tnsFuncCloseCursors = 105;
const tnsFuncCommit = 14;
const tnsFuncExecute = 94;
const tnsFuncFetch = 5;
const tnsFuncLobOp = 96;
const tnsFuncLogoff = 9;
const tnsFuncPing = 147;
const tnsFuncRollback = 15;
const tnsFuncSetEndToEndAttr = 135;
const tnsFuncReexecute = 4;
const tnsFuncReexecuteAndFetch = 78;
const tnsFuncSetSchema = 152;
const tnsFuncSessionGet = 162;
const tnsFuncSessionRelease = 163;
const tnsFuncSessionState = 176;
const tnsFuncCancelAll = 120;
const tnsFuncTpcTxnSwitch = 103;
const tnsFuncTpcTxnChangeState = 104;
const tnsFuncAqEnq = 121;
const tnsFuncAqDeq = 122;
const tnsFuncArrayAq = 145;

// =============================================================================
// Character Sets and Encodings
// =============================================================================

const tnsCharsetUtf8 = 873;
const tnsCharsetUtf16 = 2000;
const tnsEncodingUtf8 = 'UTF-8';
const tnsEncodingUtf16 = 'UTF-16LE';
const tnsEncodingMultiByte = 0x01;
const tnsEncodingConvLength = 0x02;

// =============================================================================
// Compile Time Capability Indices
// =============================================================================

const tnsCcapSqlVersion = 0;
const tnsCcapLogonTypes = 4;
const tnsCcapCtbFeatureBackport = 5;
const tnsCcapFieldVersion = 7;
const tnsCcapServerDefineConv = 8;
const tnsCcapDequeueWithSelector = 9;
const tnsCcapTtc1 = 15;
const tnsCcapOci1 = 16;
const tnsCcapTdsVersion = 17;
const tnsCcapRpcVersion = 18;
const tnsCcapRpcSig = 19;
const tnsCcapDbfVersion = 21;
const tnsCcapLob = 23;
const tnsCcapTtc2 = 26;
const tnsCcapUb2Dty = 27;
const tnsCcapOci2 = 31;
const tnsCcapClientFn = 34;
const tnsCcapOci3 = 35;
const tnsCcapTtc3 = 37;
const tnsCcapSessSignatureVersion = 39;
const tnsCcapTtc4 = 40;
const tnsCcapLob2 = 42;
const tnsCcapTtc5 = 44;
const tnsCcapVectorFeatures = 52;
const tnsCcapMax = 53;

// =============================================================================
// Compile Time Capability Values
// =============================================================================

const tnsCcapSqlVersionMax = 6;
const tnsCcapFieldVersion112 = 6;
const tnsCcapFieldVersion121 = 7;
const tnsCcapFieldVersion122 = 8;
const tnsCcapFieldVersion122Ext1 = 9;
const tnsCcapFieldVersion181 = 10;
const tnsCcapFieldVersion181Ext1 = 11;
const tnsCcapFieldVersion191 = 12;
const tnsCcapFieldVersion191Ext1 = 13;
const tnsCcapFieldVersion201 = 14;
const tnsCcapFieldVersion201Ext1 = 15;
const tnsCcapFieldVersion211 = 16;
const tnsCcapFieldVersion231 = 17;
const tnsCcapFieldVersion231Ext1 = 18;
const tnsCcapFieldVersion231Ext2 = 19;
const tnsCcapFieldVersion231Ext3 = 20;
const tnsCcapFieldVersion231Ext4 = 21;
const tnsCcapFieldVersion231Ext5 = 22;
const tnsCcapFieldVersion231Ext6 = 23;
const tnsCcapFieldVersion234 = 24;
const tnsCcapFieldVersionMax = 24;
const tnsCcapO5logon = 8;
const tnsCcapO5logonNp = 2;
const tnsCcapO7logon = 32;
const tnsCcapO8logonLongIdentifier = 64;
const tnsCcapO9logonLongPassword = 0x80;
const tnsCcapEndOfCallStatus = 0x01;
const tnsCcapIndRcd = 0x08;
const tnsCcapFastBvec = 0x20;
const tnsCcapFastSessionPropagate = 0x10;
const tnsCcapAppCtxPiggyback = 0x80;
const tnsCcapTdsVersionMax = 3;
const tnsCcapRpcVersionMax = 7;
const tnsCcapRpcSigValue = 3;
const tnsCcapDbfVersionMax = 1;
const tnsCcapLtxid = 0x08;
const tnsCcapImplicitResults = 0x10;
const tnsCcapBigChunkClr = 0x20;
const tnsCcapKeepOutOrder = 0x80;
const tnsCcapLobUb8Size = 0x01;
const tnsCcapLobEncs = 0x02;
const tnsCcapLobPrefetchData = 0x04;
const tnsCcapLobTempSize = 0x08;
const tnsCcapLobPrefetch = 0x40;
const tnsCcapLob12c = 0x80;
const tnsCcapDrcp = 0x10;
const tnsCcapZlnp = 0x04;
const tnsCcapInbandNotification = 0x04;
const tnsCcapEndOfRequest = 0x20;
const tnsCcapClientFnMax = 12;
const tnsCcapLob2Quasi = 0x01;
const tnsCcapLob22gbPrefetch = 0x04;
const tnsCcapCtbImplicitPool = 0x08;
const tnsCcapCtbOauthMsgOnErr = 0x10;
const tnsCcapVectorSupport = 0x08;
const tnsCcapVectorFeatureBinary = 0x01;
const tnsCcapVectorFeatureSparse = 0x02;
const tnsCcapTtc5SessionlessTxns = 0x20;
const tnsCcapOci3Ocssync = 0x20;

// =============================================================================
// Runtime Capability Indices
// =============================================================================

const tnsRcapCompat = 0;
const tnsRcapTtc = 6;
const tnsRcapMax = 7;

// =============================================================================
// Runtime Capability Values
// =============================================================================

const tnsRcapCompat81 = 2;
const tnsRcapTtcZeroCopy = 0x01;
const tnsRcapTtc32k = 0x04;

// =============================================================================
// Verifier Types
// =============================================================================

/// SHA1 (salted) - Oracle 11g
const tnsVerifierType11g1 = 0xb152;
const tnsVerifierType11g2 = 0x1b25;

/// MultiRound SHA-512 - Oracle 12c+
const tnsVerifierType12c = 0x4815;

// =============================================================================
// UDS Flags
// =============================================================================

const tnsUdsFlagsIsJson = 0x00000100;
const tnsUdsFlagsIsOson = 0x00000800;

// =============================================================================
// End of Call Status Flags
// =============================================================================

const tnsEocsFlagsTxnInProgress = 0x00000002;
const tnsEocsFlagsSessRelease = 0x00008000;

// =============================================================================
// Transaction Switching Op Codes
// =============================================================================

const tnsTpcTxnStart = 0x01;
const tnsTpcTxnDetach = 0x02;
const tnsTpcTxnPostDetach = 0x04;

// =============================================================================
// Transaction Change State Op Codes
// =============================================================================

const tnsTpcTxnCommit = 0x01;
const tnsTpcTxnAbort = 0x02;
const tnsTpcTxnPrepare = 0x03;
const tnsTpcTxnForget = 0x04;

// =============================================================================
// Transaction States
// =============================================================================

const tnsTpcTxnStatePrepare = 0;
const tnsTpcTxnStateRequiresCommit = 1;
const tnsTpcTxnStateCommitted = 2;
const tnsTpcTxnStateAborted = 3;
const tnsTpcTxnStateReadOnly = 4;
const tnsTpcTxnStateForgotten = 5;

// =============================================================================
// Sessionless Transaction Constants
// =============================================================================

const tnsTpcTransSessionless = 0x00000010;
const tnsTpcTransSessionlessFormat = 0x4e5c3e;
const tnsTpcTransTransactionIdSyncVersion1 = 0x01;
const tnsTpcTransTransactionIdSyncSet = 0x40;
const tnsTpcTransTransactionIdSyncUnset = 0x80;
const tnsTpcTransTransactionIdSyncServer = 0x01;
const tnsTpcTransTransactionIdSyncClient = 0x02;
const tnsTpcTransTransactionIdSyncTxendXa = 0x03;

// =============================================================================
// AQ (Advanced Queuing) Constants
// =============================================================================

// AQ Delivery modes
const tnsAqMsgPersistent = 1;
const tnsAqMsgBuffered = 2;
const tnsAqMsgPersistentOrBuffered = 3;

// AQ dequeue modes
const tnsAqDeqBrowse = 1;
const tnsAqDeqLocked = 2;
const tnsAqDeqRemove = 3;
const tnsAqDeqRemoveNodata = 4;

// AQ dequeue navigation modes
const tnsAqDeqFirstMsg = 1;
const tnsAqDeqNextMsg = 3;
const tnsAqDeqNextTransaction = 2;

// AQ dequeue visibility modes
const tnsAqDeqImmediate = 1;
const tnsAqDeqOnCommit = 2;

// AQ dequeue wait modes
const tnsAqDeqNoWait = 0;
const tnsAqDeqWaitForever = 0xFFFFFFFF;

// AQ enqueue visibility modes
const tnsAqEnqImmediate = 1;
const tnsAqEnqOnCommit = 2;

// AQ message states
const tnsAqMsgExpired = 3;
const tnsAqMsgProcessed = 2;
const tnsAqMsgReady = 0;
const tnsAqMsgWaiting = 1;

// AQ other constants
const tnsAqMsgNoDelay = 0;
const tnsAqMsgNoExpiration = -1;
const tnsAqArrayEnq = 0x01;
const tnsAqArrayDeq = 0x02;
const tnsAqArrayFlagsReturnMessageId = 0x01;
const tnsTtcEnqStreamingEnabled = 0x00000001;
const tnsTtcEnqStreamingDisabled = 0x00000000;

// AQ flags
const tnsKpdAqBufmsg = 0x02;
const tnsKpdAqEither = 0x10;

const tnsAqMessageIdLength = 16;
const tnsAqMessageVersion = 1;

const tnsAqExtKeywordAgentName = 64;
const tnsAqExtKeywordAgentAddress = 65;
const tnsAqExtKeywordAgentProtocol = 66;
const tnsAqExtKeywordOriginalMsgid = 69;

// =============================================================================
// Other Constants
// =============================================================================

const tnsEscapeChar = 253;
const tnsLongLengthIndicator = 0xFE;
const tnsNullLengthIndicator = 0;
const tnsMaxRowidLength = 18;
const tnsDurationSession = 10;
const tnsMaxLongLength = 0x7fffffff;
const tnsSdu = 8192;
const tnsTdu = 65535;
const tnsMaxConnectData = 230;
const tnsMaxUrowidLength = 3950;
const tnsServerConvertsChars = 0x01;

// DRCP release mode
const drcpDeauthenticate = 0x00000002;

// =============================================================================
// Database Object Image Flags
// =============================================================================

const tnsObjIsVersion81 = 0x80;
const tnsObjIsDegenerate = 0x10;
const tnsObjIsCollection = 0x08;
const tnsObjNoPrefixSeg = 0x04;
const tnsObjImageVersion = 1;

// Database object flags
const tnsObjMaxShortLength = 245;
const tnsObjAtomicNull = 253;
const tnsObjNonNullOid = 0x02;
const tnsObjHasExtentOid = 0x08;
const tnsObjTopLevel = 0x01;
const tnsObjHasIndexes = 0x10;

// Database object collection types
const tnsObjPlsqlIndexTable = 1;
const tnsObjNestedTable = 2;
const tnsObjVarray = 3;

// Database object TDS type codes
const tnsObjTdsTypeChar = 1;
const tnsObjTdsTypeDate = 2;
const tnsObjTdsTypeFloat = 5;
const tnsObjTdsTypeNumber = 6;
const tnsObjTdsTypeVarchar = 7;
const tnsObjTdsTypeBoolean = 8;
const tnsObjTdsTypeRaw = 19;
const tnsObjTdsTypeTimestamp = 21;
const tnsObjTdsTypeTimestampTz = 23;
const tnsObjTdsTypeObj = 27;
const tnsObjTdsTypeColl = 28;
const tnsObjTdsTypeClob = 29;
const tnsObjTdsTypeBlob = 30;
const tnsObjTdsTypeTimestampLtz = 33;
const tnsObjTdsTypeBinaryFloat = 37;
const tnsObjTdsTypeStartEmbedAdt = 39;
const tnsObjTdsTypeEndEmbedAdt = 40;
const tnsObjTdsTypeSubtypeMarker = 43;
const tnsObjTdsTypeEmbedAdtInfo = 44;
const tnsObjTdsTypeBinaryDouble = 45;

// =============================================================================
// XML Type Constants
// =============================================================================

const tnsXmlTypeLob = 0x0001;
const tnsXmlTypeString = 0x0004;
const tnsXmlTypeFlagSkipNext4 = 0x100000;

// =============================================================================
// Error Constants
// =============================================================================

const tnsErrInconsistentDataTypes = 932;
const tnsErrVarNotInSelectList = 1007;
const tnsErrInbandMessage = 12573;
const tnsErrInvalidServiceName = 12514;
const tnsErrInvalidSid = 12505;
const tnsErrNoDataFound = 1403;
const tnsErrSessionShutdown = 12572;
const tnsErrNoMessagesFound = 25228;

// =============================================================================
// Warning Constants
// =============================================================================

const tnsWarnCompilationCreate = 0x20;

// =============================================================================
// Vector Constants
// =============================================================================

const tnsVectorMaxLength = 1048576;
const vectorFormatFlex = 0;
const vectorMetaFlagFlexibleDim = 1;
const vectorMetaFlagSparse = 2;

// =============================================================================
// Buffer Constants
// =============================================================================

const packetHeaderSize = 8;
const numberAsTextChars = 172;
const chunkedBytesChunkSize = 65536;
const bufferChunkSize = 65536;
const tnsMaxShortLength = 252;

// =============================================================================
// Network Header Flags
// =============================================================================

const tnsDataFlagsEndOfRequest = 0x2000;

// =============================================================================
// Driver Information
// =============================================================================

const driverName = 'dart-oracledb thn';
const versionMajor = 0;
const versionMinor = 1;
const versionPatch = 0;
const clientVersion = (versionMajor << 24) | (versionMinor << 20) | (versionPatch << 12);

// =============================================================================
// Base64 Alphabet
// =============================================================================

final tnsBase64AlphabetArray = Uint8List.fromList(
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.codeUnits,
);

// =============================================================================
// Extent OID
// =============================================================================

final tnsExtentOid = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01,
]);

// =============================================================================
// Recoverable Errors (for connection recovery)
// =============================================================================

const recoverableErrors = <int>{
  28,    // session killed
  31,    // session marked for kill
  376,   // file not accessible
  603,   // session was marked for death
  1012,  // not logged on
  1033,  // initialization/shutdown in progress
  1034,  // not available
  1089,  // immediate shutdown in progress
  1090,  // shutdown in progress
  1092,  // instance terminated
  1115,  // IO error reading block from file
  2396,  // exceeded maximum idle time
  3113,  // end-of-file on communication channel
  3114,  // not connected to ORACLE
  3135,  // connection lost contact
  12153, // TNS: not connected
  12514, // TNS: listener does not currently know of service
  12537, // TNS: connection closed
  12547, // TNS: lost contact
  12570, // TNS: packet reader failure
  12571, // TNS: packet writer failure
  12583, // TNS: no reader
  12757, // instance not registered with listener
  16456, // timeout waiting for connection
};
