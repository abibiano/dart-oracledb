/// Connection ping message.
library;

import '../constants.dart';
import '../protocol/ttc_buffer.dart';
import 'message.dart';

/// Ping request for connection health check
class PingRequest extends Message {
  const PingRequest();

  @override
  TtcMessageType get type => TtcMessageType.function;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.ping.value);
  }
}
