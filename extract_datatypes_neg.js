// Extract data types negotiation message from node-oracledb
import oracledb from 'oracledb';
import net from 'net';

let capturedPackets = [];
const originalWrite = net.Socket.prototype.write;

net.Socket.prototype.write = function(data, ...args) {
  if (Buffer.isBuffer(data)) {
    capturedPackets.push(Buffer.from(data));
  }
  return originalWrite.call(this, data, ...args);
};

async function extractDataTypesNeg() {
  try {
    console.log('Connecting with node-oracledb to capture messages...\n');

    const connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    await connection.close();

    // Find the large DATA packet (packet 2 - contains protocol + datatypes + auth)
    for (let i = 0; i < capturedPackets.length; i++) {
      const packet = capturedPackets[i];

      // Skip short packets
      if (packet.length < 100) continue;

      // Look for DATA packet with large payload
      if (packet.length >= 8 && packet[4] === 6) {
        console.log(`Analyzing packet ${i + 1} (${packet.length} bytes)...`);

        // Skip TNS header (8 bytes) + data flags (2 bytes)
        const ttcPayload = packet.slice(10);

        console.log(`\nTTC Payload starts at offset 10, length: ${ttcPayload.length} bytes\n`);

        // Look for TTC message types in payload
        let offset = 0;
        let msgNum = 0;

        while (offset < ttcPayload.length && offset < 500) {
          const msgType = ttcPayload[offset];
          msgNum++;

          console.log(`--- TTC Message ${msgNum} at offset ${offset} (0x${offset.toString(16)}) ---`);
          console.log(`Message type: ${msgType} (0x${msgType.toString(16)})`);

          if (msgType === 1) {
            // Protocol negotiation
            console.log('Type: Protocol Negotiation Request');
            const version = ttcPayload[offset + 1];
            console.log(`  Protocol version: ${version}`);
            console.log(`  First 50 bytes:`);
            const chunk = ttcPayload.slice(offset, offset + 50);
            console.log(`  ${chunk.toString('hex').match(/.{1,2}/g).join(' ')}`);
            break; // We'll handle finding data types next
          } else if (msgType === 2) {
            // Data types negotiation
            console.log('Type: Data Types Negotiation');
            const charset1 = (ttcPayload[offset + 2] << 8) | ttcPayload[offset + 1];
            const charset2 = (ttcPayload[offset + 4] << 8) | ttcPayload[offset + 3];
            const flags = ttcPayload[offset + 5];
            const compileLen = ttcPayload[offset + 6];
            const runtimeLen = ttcPayload[offset + 7 + compileLen];

            console.log(`  Charset 1: ${charset1}`);
            console.log(`  Charset 2: ${charset2}`);
            console.log(`  Encoding flags: 0x${flags.toString(16).padStart(2, '0')}`);
            console.log(`  Compile caps length: ${compileLen} bytes`);

            const compileCaps = ttcPayload.slice(offset + 7, offset + 7 + compileLen);
            console.log(`  Compile caps: ${compileCaps.toString('hex').match(/.{1,2}/g).join(' ')}`);
            console.log(`  Compile caps (indexed):`);
            for (let j = 0; j < compileCaps.length; j++) {
              if (compileCaps[j] !== 0) {
                console.log(`    [${j}] = 0x${compileCaps[j].toString(16).padStart(2, '0')} (${compileCaps[j]})`);
              }
            }

            console.log(`  Runtime caps length: ${runtimeLen} bytes`);
            const runtimeCaps = ttcPayload.slice(offset + 8 + compileLen, offset + 8 + compileLen + runtimeLen);
            console.log(`  Runtime caps: ${runtimeCaps.toString('hex').match(/.{1,2}/g).join(' ')}`);
            console.log(`  Runtime caps (indexed):`);
            for (let j = 0; j < runtimeCaps.length; j++) {
              if (runtimeCaps[j] !== 0) {
                console.log(`    [${j}] = 0x${runtimeCaps[j].toString(16).padStart(2, '0')} (${runtimeCaps[j]})`);
              }
            }

            console.log(`\n  Full data types message (first 100 bytes):`);
            const dataTypesMsg = ttcPayload.slice(offset, offset + 100);
            for (let j = 0; j < dataTypesMsg.length; j += 16) {
              const chunk = dataTypesMsg.slice(j, j + 16);
              const hexStr = chunk.toString('hex').match(/.{1,2}/g).join(' ').padEnd(48);
              console.log(`  ${(offset + j).toString(16).padStart(4, '0')}: ${hexStr}`);
            }

            break;
          } else {
            // Unknown - try next byte
            offset++;
          }
        }

        break;
      }
    }

  } catch (err) {
    console.error('Error:', err.message);
  }
}

extractDataTypesNeg();
