/// TTC PING message for connection health checking.
library;

import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

/// TTC PING message for connection health checking.
///
/// Sends a lightweight ping to the Oracle server to verify
/// the connection is alive and responsive.
///
/// Example:
/// ```dart
/// final ping = PingMessage();
/// final bytes = ping.toBytes();
/// // Send bytes to server and await response
/// ```
class PingMessage extends Message {
  /// Creates a ping message with an optional sequence number.
  PingMessage({super.sequence}) : super(messageType: ttcPing);

  @override
  void encode(WriteBuffer buffer) {
    // Ping message format: single byte function code
    buffer.writeUint8(messageType);
  }
}
