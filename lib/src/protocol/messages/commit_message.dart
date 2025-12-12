/// Transaction commit message.
library;

import '../constants.dart';
import '../protocol/ttc_buffer.dart';
import 'message.dart';

/// Commit transaction request
class CommitRequest extends Message {
  const CommitRequest();

  @override
  TtcMessageType get type => TtcMessageType.function;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.commit.value);
  }
}
