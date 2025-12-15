/// TTC Protocol orchestrator for Oracle wire protocol.
///
/// Manages the TTC protocol state, sequence numbers, and message
/// creation/validation for client-server communication.
library;

import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import 'capabilities.dart';
import 'constants.dart';
import 'ttc_packet.dart';

final _log = Logger('Protocol');

/// Protocol connection states.
enum ProtocolState {
  /// Not connected to server.
  disconnected,

  /// Negotiating protocol capabilities.
  negotiating,

  /// Connected and ready for operations.
  connected,
}

/// TTC Protocol orchestrator.
///
/// Manages the TTC protocol layer including:
/// - Connection state transitions
/// - Sequence number management
/// - Packet creation with proper sequencing
/// - Response validation
///
/// Example usage:
/// ```dart
/// final protocol = TtcProtocol();
///
/// // Begin negotiation
/// protocol.beginNegotiation();
///
/// // After successful negotiation
/// protocol.completeNegotiation(serverCapabilities);
///
/// // Create packets for operations
/// final packet = protocol.createPacket(
///   functionCode: ttcExecute,
///   payload: queryBytes,
/// );
///
/// // Validate responses
/// if (protocol.validateResponse(request, response)) {
///   // Process response
/// }
/// ```
class TtcProtocol {
  /// Creates a new protocol orchestrator in disconnected state.
  TtcProtocol()
      : _state = ProtocolState.disconnected,
        _sequence = 0,
        _capabilities = null;

  ProtocolState _state;
  int _sequence;
  Capabilities? _capabilities;

  /// Current protocol state.
  ProtocolState get state => _state;

  /// Current sequence number (without incrementing).
  int get currentSequence => _sequence;

  /// Negotiated capabilities, or null if not yet negotiated.
  Capabilities? get negotiatedCapabilities => _capabilities;

  /// Whether the protocol is in connected state.
  bool get isConnected => _state == ProtocolState.connected;

  /// Gets and increments the sequence number.
  ///
  /// Sequence numbers wrap around at 256 (0-255 range).
  int nextSequence() {
    final seq = _sequence;
    _sequence = (_sequence + 1) & 0xFF;
    return seq;
  }

  /// Begins protocol negotiation.
  ///
  /// Transitions state from disconnected to negotiating.
  /// Throws [OracleException] if not in disconnected state.
  void beginNegotiation() {
    if (_state != ProtocolState.disconnected) {
      _log.warning(
        'Invalid state transition: beginNegotiation called in state $_state',
      );
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Protocol error: cannot begin negotiation in state $_state',
      );
    }
    _log.fine('Protocol state: disconnected → negotiating');
    _state = ProtocolState.negotiating;
  }

  /// Completes protocol negotiation with the given capabilities.
  ///
  /// Transitions state from negotiating to connected.
  /// Throws [OracleException] if not in negotiating state.
  void completeNegotiation(Capabilities capabilities) {
    if (_state != ProtocolState.negotiating) {
      _log.warning(
        'Invalid state transition: completeNegotiation called in state $_state',
      );
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'Protocol error: cannot complete negotiation in state $_state',
      );
    }
    _capabilities = capabilities;
    _state = ProtocolState.connected;
    _log.fine(
      'Protocol state: negotiating → connected '
      '(version=${capabilities.protocolVersion})',
    );
  }

  /// Disconnects the protocol and resets state.
  void disconnect() {
    _log.fine('Protocol state: $_state → disconnected');
    _state = ProtocolState.disconnected;
    _capabilities = null;
    _sequence = 0;
  }

  /// Creates a TTC packet with auto-assigned sequence number.
  TtcPacket createPacket({
    required int functionCode,
    required Uint8List payload,
    int dataFlags = 0,
  }) {
    return TtcPacket(
      functionCode: functionCode,
      payload: payload,
      sequence: nextSequence(),
      dataFlags: dataFlags,
    );
  }

  /// Creates a ping packet for connection health check.
  TtcPacket createPingPacket() {
    return createPacket(
      functionCode: ttcPing,
      payload: Uint8List(0),
    );
  }

  /// Creates a close packet to terminate the connection.
  TtcPacket createClosePacket() {
    return createPacket(
      functionCode: ttcClose,
      payload: Uint8List(0),
    );
  }

  /// Validates that a response matches the expected request.
  ///
  /// Checks that the sequence numbers match.
  bool validateResponse(TtcPacket request, TtcPacket response) {
    return request.sequence == response.sequence;
  }
}
