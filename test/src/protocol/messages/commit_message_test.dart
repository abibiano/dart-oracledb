import 'dart:typed_data';

import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/commit_message.dart';
import 'package:test/test.dart';

void main() {
  group('CommitRequest', () {
    test('encodes with correct function code (0x0E)', () {
      final msg = CommitRequest();
      final bytes = msg.toBytes();
      expect(bytes[0], equals(ttcCommit)); // 0x0E = 14
    });

    test('encodes minimal message size', () {
      final msg = CommitRequest();
      final bytes = msg.toBytes();
      // Commit message should be minimal - just function code
      expect(bytes.length, equals(1));
    });

    test('messageType is ttcCommit', () {
      final msg = CommitRequest();
      expect(msg.messageType, equals(ttcCommit));
    });

    test('sequence number defaults to 0', () {
      final msg = CommitRequest();
      expect(msg.sequence, equals(0));
    });

    test('accepts custom sequence number', () {
      final msg = CommitRequest(sequence: 42);
      expect(msg.sequence, equals(42));
    });
  });

  group('CommitResponse', () {
    test('decodes success response (status = 0)', () {
      // Create a minimal success response
      final data = Uint8List.fromList([0x00]); // Status byte = 0 (success)
      final response = CommitResponse.decode(data);
      expect(response.isSuccess, isTrue);
      expect(response.errorCode, isNull);
      expect(response.errorMessage, isNull);
    });

    test('decodes error response with error code and message', () {
      // Error response: status=1, errorCode=12345 (0x3039), msgLen=5, msg="ERROR"
      final data = Uint8List.fromList([
        0x01, // Status byte = 1 (error)
        0x30, 0x39, // Error code = 12345 (big-endian)
        0x05, // Message length = 5
        0x45, 0x52, 0x52, 0x4F, 0x52, // "ERROR" in ASCII
      ]);
      final response = CommitResponse.decode(data);
      expect(response.isSuccess, isFalse);
      expect(response.errorCode, equals(12345));
      expect(response.errorMessage, equals('ERROR'));
    });

    test('decodes error response with zero-length message', () {
      // Error response: status=1, errorCode=1234, msgLen=0
      final data = Uint8List.fromList([
        0x01, // Status byte = 1 (error)
        0x04, 0xD2, // Error code = 1234 (big-endian)
        0x00, // Message length = 0
      ]);
      final response = CommitResponse.decode(data);
      expect(response.isSuccess, isFalse);
      expect(response.errorCode, equals(1234));
      expect(response.errorMessage, isNull);
    });

    test('throws OracleException on invalid data', () {
      // Empty data should fail
      final data = Uint8List.fromList([]);
      expect(
        () => CommitResponse.decode(data),
        throwsA(isA<Object>()),
      );
    });
  });
}
