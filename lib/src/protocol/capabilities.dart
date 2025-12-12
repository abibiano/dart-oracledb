/// Client and server capability negotiation.
///
/// Ported from node-oracledb lib/thin/protocol/capabilities.js
library;

import 'dart:typed_data';

import 'constants.dart';

/// Negotiates compile-time and runtime capabilities with the Oracle server.
class Capabilities {
  /// Protocol version from connection attributes
  int protocolVersion = 0;

  /// TTC field version for capability negotiation
  int ttcFieldVersion = tnsCcapFieldVersionMax;

  /// Whether 12c logon is supported
  bool supports12cLogon = true;

  /// Whether out-of-band data is supported
  bool supportsOob = false;

  /// National character set ID
  int nCharsetId = tnsCharsetUtf16;

  /// Database character set ID
  int charsetId = tnsCharsetUtf8;

  /// Maximum string size (4000 or 32767)
  int maxStringSize = 0;

  /// Compile-time capabilities (53 bytes)
  late Uint8List compileCaps;

  /// Runtime capabilities (7 bytes)
  late Uint8List runtimeCaps;

  /// Creates capabilities from connection attributes.
  Capabilities({int? version, bool endOfRequestSupport = false}) {
    protocolVersion = version ?? 0;
    compileCaps = Uint8List(tnsCcapMax);
    runtimeCaps = Uint8List(tnsRcapMax);
    initCompileCaps(endOfRequestSupport: endOfRequestSupport);
    initRuntimeCaps();
  }

  /// Adjusts capabilities based on server compile-time capabilities.
  void adjustForServerCompileCaps(
    Uint8List serverCaps, {
    required bool endOfRequestSupport,
    required void Function(bool) setEndOfRequestSupport,
  }) {
    if (serverCaps[tnsCcapFieldVersion] < ttcFieldVersion) {
      ttcFieldVersion = serverCaps[tnsCcapFieldVersion];
      compileCaps[tnsCcapFieldVersion] = ttcFieldVersion;
    }

    // endOfRequestSupport used only from 23.4 onwards and not for 23.3
    if (ttcFieldVersion < tnsCcapFieldVersion234 && endOfRequestSupport) {
      compileCaps[tnsCcapTtc4] ^= tnsCcapEndOfRequest;
      setEndOfRequestSupport(false);
    }
  }

  /// Adjusts capabilities based on server runtime capabilities.
  void adjustForServerRuntimeCaps(Uint8List serverCaps) {
    if ((serverCaps[tnsRcapTtc] & tnsRcapTtc32k) != 0) {
      maxStringSize = 32767;
    } else {
      maxStringSize = 4000;
    }
  }

  /// Initializes compile-time capabilities.
  void initCompileCaps({bool endOfRequestSupport = false}) {
    compileCaps[tnsCcapSqlVersion] = tnsCcapSqlVersionMax;

    compileCaps[tnsCcapLogonTypes] = tnsCcapO5logon |
        tnsCcapO5logonNp |
        tnsCcapO7logon |
        tnsCcapO8logonLongIdentifier |
        tnsCcapO9logonLongPassword;

    compileCaps[tnsCcapFieldVersion] = ttcFieldVersion;
    compileCaps[tnsCcapServerDefineConv] = 1;
    compileCaps[tnsCcapDequeueWithSelector] = 1;

    compileCaps[tnsCcapTtc1] =
        tnsCcapFastBvec | tnsCcapEndOfCallStatus | tnsCcapIndRcd;

    compileCaps[tnsCcapOci1] =
        tnsCcapFastSessionPropagate | tnsCcapAppCtxPiggyback;

    compileCaps[tnsCcapTdsVersion] = tnsCcapTdsVersionMax;
    compileCaps[tnsCcapRpcVersion] = tnsCcapRpcVersionMax;
    compileCaps[tnsCcapRpcSig] = tnsCcapRpcSigValue;
    compileCaps[tnsCcapDbfVersion] = tnsCcapDbfVersionMax;

    compileCaps[tnsCcapLob] = tnsCcapLobUb8Size |
        tnsCcapLobEncs |
        tnsCcapLobPrefetch |
        tnsCcapLobTempSize |
        tnsCcapLob12c |
        tnsCcapLobPrefetchData;

    compileCaps[tnsCcapUb2Dty] = 1;

    compileCaps[tnsCcapLob2] = tnsCcapLob2Quasi | tnsCcapLob22gbPrefetch;

    compileCaps[tnsCcapTtc3] = tnsCcapImplicitResults |
        tnsCcapBigChunkClr |
        tnsCcapKeepOutOrder |
        tnsCcapLtxid;

    compileCaps[tnsCcapOci3] = tnsCcapOci3Ocssync;
    compileCaps[tnsCcapTtc2] = tnsCcapZlnp;
    compileCaps[tnsCcapOci2] = tnsCcapDrcp;
    compileCaps[tnsCcapClientFn] = tnsCcapClientFnMax;
    compileCaps[tnsCcapSessSignatureVersion] = tnsCcapFieldVersion122;

    compileCaps[tnsCcapTtc4] = tnsCcapInbandNotification;
    if (endOfRequestSupport) {
      compileCaps[tnsCcapTtc4] |= tnsCcapEndOfRequest;
    }

    compileCaps[tnsCcapCtbFeatureBackport] =
        tnsCcapCtbImplicitPool | tnsCcapCtbOauthMsgOnErr;

    compileCaps[tnsCcapTtc5] = tnsCcapVectorSupport | tnsCcapTtc5SessionlessTxns;

    compileCaps[tnsCcapVectorFeatures] =
        tnsCcapVectorFeatureBinary | tnsCcapVectorFeatureSparse;
  }

  /// Initializes runtime capabilities.
  void initRuntimeCaps() {
    runtimeCaps[tnsRcapCompat] = tnsRcapCompat81;
    runtimeCaps[tnsRcapTtc] = tnsRcapTtcZeroCopy | tnsRcapTtc32k;
  }

  /// Checks that the national character set is UTF-16.
  void checkNCharsetId() {
    if (nCharsetId != tnsCharsetUtf16) {
      throw UnsupportedError(
        'National character set $nCharsetId is not supported. '
        'Only UTF-16 ($tnsCharsetUtf16) is supported.',
      );
    }
  }
}
