// Captures EXACT batched packet bytes from node-oracledb
import oracledb from 'oracledb';
import net from 'net';
import fs from 'fs';

let capturedPackets = [];
const originalWrite = net.Socket.prototype.write;

net.Socket.prototype.write = function(data, ...args) {
  if (Buffer.isBuffer(data)) {
    capturedPackets.push({
      length: data.length,
      data: Buffer.from(data)
    });
  }
  return originalWrite.call(this, data, ...args);
};

async function captureAndSave() {
  try {
    const connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    await connection.close();

    // Find the batched packet (should be ~2790 bytes)
    for (let i = 0; i < capturedPackets.length; i++) {
      const pkt = capturedPackets[i];
      if (pkt.length > 2000 && pkt.length < 3000) {
        console.log(`\nFound batched packet ${i + 1}: ${pkt.length} bytes`);

        // Save to file for comparison
        fs.writeFileSync('node_batched.bin', pkt.data);

        // Extract just the TTC messages (skip TNS header + data flags)
        const ttcData = pkt.data.slice(10); // 8-byte TNS header + 2-byte data flags
        fs.writeFileSync('node_ttc_batch.bin', ttcData);

        console.log(`Saved to node_batched.bin (${pkt.length} bytes)`);
        console.log(`TTC data: ${ttcData.length} bytes`);
        console.log(`\nFirst 100 bytes of TTC:`);
        console.log(ttcData.slice(0, 100).toString('hex').match(/.{1,2}/g).join(' '));
        break;
      }
    }
  } catch (err) {
    console.error('Error:', err.message);
  }
}

captureAndSave();
