const oracledb = require('oracledb');
const net = require('net');
const fs = require('fs');

// Monkey-patch net.Socket.write to capture AUTH_PHASE_TWO packet
const originalWrite = net.Socket.prototype.write;
let packetCount = 0;
let authPhaseOneReceived = false;
const packets = [];

net.Socket.prototype.write = function(data, encoding, callback) {
  packetCount++;

  // Check if this is a TNS packet
  if (data && data.length >= 8) {
    // TNS packet header: length(2) + checksum(2) + type(1) + flags(1) + hdrChecksum(2)
    const tnsLength = (data[0] << 8) | data[1];
    const tnsType = data[4];
    const tnsFlags = data[5];

    packets.push({num: packetCount, type: tnsType, length: tnsLength});

    // TNS DATA packet is type 6
    if (tnsType === 6 && data.length > 10) {
      // Data flags are at offset 8-9 (2 bytes BE)
      const dataFlags = (data[8] << 8) | data[9];

      // TTC payload starts at offset 10
      const ttcPayload = data.slice(10);

      if (ttcPayload.length > 0) {
        const ttcMsgType = ttcPayload[0];

        // Type 34 = FAST_AUTH
        if (ttcMsgType === 34) {
          authPhaseOneReceived = true;
          packets.push({msg: 'FAST_AUTH', ttcLen: ttcPayload.length});
        }
        // Type 3 = Function message (could be AUTH_PHASE_TWO)
        else if (ttcMsgType === 3 && authPhaseOneReceived) {
          const functionCode = ttcPayload[1];

          // 0x73 = AUTH_PHASE_TWO
          if (functionCode === 0x73) {
            // Save to file
            fs.writeFileSync('node_auth_phase_two_tns.bin', data);
            fs.writeFileSync('node_auth_phase_two_ttc.bin', ttcPayload);
            packets.push({found: 'AUTH_PHASE_TWO', ttcLen: ttcPayload.length, tnsLen: data.length, dataFlags});
          }
        }
      }
    }
  }

  return originalWrite.call(this, data, encoding, callback);
};

// Test connection
async function test() {
  let connection;

  try {
    connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    await connection.close();

  } catch (err) {
    // Connection might fail, but we already captured packets
  } finally {
    // Use process.stdout.write to avoid recursive call
    process.stdout.write('\\n=== Packet Summary ===\\n');
    process.stdout.write(JSON.stringify(packets, null, 2) + '\\n');
  }
}

test();
