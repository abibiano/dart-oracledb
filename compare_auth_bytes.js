// Compare AUTH_PHASE_ONE bytes between node-oracledb and dart-oracledb
import oracledb from 'oracledb';
import net from 'net';

// Intercept the socket to capture raw bytes
let capturedBytes = [];
const originalWrite = net.Socket.prototype.write;

net.Socket.prototype.write = function(data, ...args) {
  if (Buffer.isBuffer(data)) {
    capturedBytes.push(Buffer.from(data));
  }
  return originalWrite.call(this, data, ...args);
};

async function captureNodeAuth() {
  capturedBytes = [];

  try {
    const connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    await connection.close();

    // Find AUTH_PHASE_ONE message (contains function code 0x76)
    for (let i = 0; i < capturedBytes.length; i++) {
      const buf = capturedBytes[i];
      const hex = buf.toString('hex');

      // Look for TTC function message (type 3) with AUTH_PHASE_ONE (0x76)
      // Pattern: TNS DATA packet containing 0x03 0x76
      if (hex.includes('0376')) {
        console.log(`\n=== Packet ${i + 1} (contains AUTH_PHASE_ONE) ===`);
        console.log('Length:', buf.length, 'bytes');
        console.log('Hex:', hex.match(/.{1,2}/g).join(' '));
        console.log('\nFormatted:');
        for (let j = 0; j < buf.length; j += 16) {
          const chunk = buf.slice(j, j + 16);
          const hexStr = chunk.toString('hex').match(/.{1,2}/g).join(' ').padEnd(48);
          const asciiStr = Array.from(chunk).map(b =>
            (b >= 32 && b < 127) ? String.fromCharCode(b) : '.'
          ).join('');
          console.log(`  ${j.toString(16).padStart(4, '0')}: ${hexStr} ${asciiStr}`);
        }
      }
    }
  } catch (err) {
    console.error('Error:', err.message);
  }
}

console.log('Capturing node-oracledb AUTH_PHASE_ONE bytes...\n');
captureNodeAuth();
