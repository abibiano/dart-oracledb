/// Transaction rollback message.
library;

import '../constants.dart';
import '../protocol/ttc_buffer.dart';
import 'message.dart';

/// Rollback transaction request
class RollbackRequest extends Message {
  const RollbackRequest();

  @override
  TtcMessageType get type => TtcMessageType.function;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.rollback.value);
  }
}
