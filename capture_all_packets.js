// Capture ALL packets from node-oracledb connection flow
// This will show CONNECT, ACCEPT, protocol neg, data types neg, and AUTH
import oracledb from 'oracledb';
import net from 'net';

// Intercept the socket to capture raw bytes
let packetNumber = 0;
const originalWrite = net.Socket.prototype.write;

net.Socket.prototype.write = function(data, ...args) {
  if (Buffer.isBuffer(data)) {
    packetNumber++;
    console.log(`\n=== PACKET ${packetNumber} (${data.length} bytes) ===`);

    // Try to identify packet type from TNS header
    if (data.length >= 8) {
      const packetLength = (data[0] << 8) | data[1];
      const packetType = data[4];
      const typeNames = {
        1: 'CONNECT',
        2: 'ACCEPT',
        3: 'ACK',
        4: 'REFUSE',
        5: 'REDIRECT',
        6: 'DATA',
        11: 'RESEND',
        12: 'MARKER',
        13: 'ATTENTION',
        14: 'CONTROL'
      };

      console.log(`TNS Header: length=${packetLength}, type=${typeNames[packetType] || packetType}`);

      // For DATA packets, check TTC message type
      if (packetType === 6 && data.length >= 10) {
        const ttcMsgType = data[10]; // After 8-byte TNS header + 2-byte data flags
        const msgTypeNames = {
          1: 'Protocol Negotiation',
          2: 'Data Types Negotiation',
          3: 'Function (includes AUTH)',
          6: 'Describe',
          8: 'Execute',
          11: 'Fetch',
          17: 'Ping'
        };

        // Check for AUTH_PHASE_ONE (0x76) or AUTH_PHASE_TWO (0x73)
        if (ttcMsgType === 3 && data.length >= 12) {
          const funcCode = data[11];
          if (funcCode === 0x76) {
            console.log(`TTC: Function message - AUTH_PHASE_ONE`);
          } else if (funcCode === 0x73) {
            console.log(`TTC: Function message - AUTH_PHASE_TWO`);
          } else {
            console.log(`TTC: Function message (code 0x${funcCode.toString(16)})`);
          }
        } else {
          console.log(`TTC: ${msgTypeNames[ttcMsgType] || 'Unknown'} (type ${ttcMsgType})`);
        }
      }
    }

    // Hex dump with ASCII
    for (let j = 0; j < data.length; j += 16) {
      const chunk = data.slice(j, j + 16);
      const hexStr = chunk.toString('hex').match(/.{1,2}/g).join(' ').padEnd(48);
      const asciiStr = Array.from(chunk).map(b =>
        (b >= 32 && b < 127) ? String.fromCharCode(b) : '.'
      ).join('');
      console.log(`  ${j.toString(16).padStart(4, '0')}: ${hexStr} ${asciiStr}`);
    }
  }
  return originalWrite.call(this, data, ...args);
};

async function captureAllPackets() {
  try {
    console.log('Connecting to Oracle with node-oracledb...\n');

    const connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    console.log('\n✓ Authentication successful!\n');
    await connection.close();

  } catch (err) {
    console.error('\n✗ Error:', err.message);
  }
}

captureAllPackets();
