import '../errors.dart';

/// The default Oracle database listener port.
const int defaultOraclePort = 1521;

/// Error code for invalid EZ Connect string format.
const int _oraInvalidConnectString =
    12154; // TNS:could not resolve the connect identifier

/// Connection information parsed from an EZ Connect string.
///
/// Contains the host, port, and service name needed to establish
/// a connection to an Oracle database.
class ConnectionInfo {
  /// Creates connection info with the given host, port, and service name.
  const ConnectionInfo({
    required this.host,
    required this.port,
    required this.serviceName,
  });

  /// The database server hostname or IP address.
  final String host;

  /// The listener port number.
  final int port;

  /// The Oracle service name.
  final String serviceName;

  @override
  String toString() =>
      'ConnectionInfo(host: $host, port: $port, serviceName: $serviceName)';
}

/// Parses an EZ Connect string into connection information.
///
/// EZ Connect format: `host[:port]/service_name`
///
/// Examples:
/// - `localhost:1521/FREEPDB1`
/// - `localhost/FREEPDB1` (uses default port 1521)
/// - `192.168.1.100:1522/ORCL`
/// - `db.example.com/pdb1.localdomain`
///
/// Throws [OracleException] if the format is invalid.
ConnectionInfo parseEZConnect(String connectString) {
  final trimmed = connectString.trim();

  if (trimmed.isEmpty) {
    throw const OracleException(
      errorCode: _oraInvalidConnectString,
      message: 'EZ Connect string cannot be empty',
    );
  }

  // Find the service name separator
  final slashIndex = trimmed.indexOf('/');
  if (slashIndex == -1) {
    throw OracleException(
      errorCode: _oraInvalidConnectString,
      message:
          'EZ Connect string must contain "/" followed by service name: $trimmed',
    );
  }

  // Extract service name
  final serviceName = trimmed.substring(slashIndex + 1);
  if (serviceName.isEmpty) {
    throw OracleException(
      errorCode: _oraInvalidConnectString,
      message: 'EZ Connect string missing service name after "/": $trimmed',
    );
  }

  // Extract host and optional port
  final hostPort = trimmed.substring(0, slashIndex);
  if (hostPort.isEmpty) {
    throw OracleException(
      errorCode: _oraInvalidConnectString,
      message: 'EZ Connect string missing host: $trimmed',
    );
  }

  String host;
  int port;

  // Check for port separator
  final colonIndex = hostPort.lastIndexOf(':');
  if (colonIndex == -1) {
    // No port specified, use default
    host = hostPort;
    port = defaultOraclePort;
  } else {
    host = hostPort.substring(0, colonIndex);
    final portStr = hostPort.substring(colonIndex + 1);

    if (host.isEmpty) {
      throw OracleException(
        errorCode: _oraInvalidConnectString,
        message: 'EZ Connect string missing host before port: $trimmed',
      );
    }

    // Parse port number
    final parsedPort = int.tryParse(portStr);
    if (parsedPort == null) {
      throw OracleException(
        errorCode: _oraInvalidConnectString,
        message: 'EZ Connect string has invalid port "$portStr": $trimmed',
      );
    }

    if (parsedPort < 1 || parsedPort > 65535) {
      throw OracleException(
        errorCode: _oraInvalidConnectString,
        message:
            'EZ Connect string port must be between 1 and 65535, got $parsedPort: $trimmed',
      );
    }

    port = parsedPort;
  }

  return ConnectionInfo(
    host: host,
    port: port,
    serviceName: serviceName,
  );
}
