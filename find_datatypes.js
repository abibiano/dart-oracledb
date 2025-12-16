// Find data types negotiation in node-oracledb capture
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

async function findDataTypesNeg() {
  try {
    console.log('Connecting with node-oracledb...\n');

    const connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    await connection.close();

    // Find the large DATA packet
    for (let i = 0; i < capturedPackets.length; i++) {
      const packet = capturedPackets[i];

      if (packet.length < 100) continue;

      // DATA packet
      if (packet.length >= 8 && packet[4] === 6) {
        const ttcPayload = packet.slice(10); // Skip TNS header + data flags

        // Search for TTC message type 2 (data types negotiation)
        for (let offset = 0; offset < ttcPayload.length - 100; offset++) {
          if (ttcPayload[offset] === 2) {
            // Verify it looks like data types negotiation
            // Should have: [2] [charset_le_16] [charset_le_16] [flags] [compile_len] [compile_caps...] [runtime_len] [runtime_caps...]
            const charset1 = ttcPayload[offset + 1] | (ttcPayload[offset + 2] << 8);
            const charset2 = ttcPayload[offset + 3] | (ttcPayload[offset + 4] << 8);
            const flags = ttcPayload[offset + 5];
            const compileLen = ttcPayload[offset + 6];

            // Sanity check: charset should be reasonable (typically 873 for UTF-8)
            if (charset1 >= 1 && charset1 <= 2000 && charset2 >= 1 && charset2 <= 2000) {
              console.log(`\n=== FOUND DATA TYPES NEGOTIATION at offset ${offset} ===\n`);
              console.log(`Message type: 2 (Data Types Negotiation)`);
              console.log(`Charset 1 (LE): ${charset1} (0x${charset1.toString(16)})`);
              console.log(`Charset 2 (LE): ${charset2} (0x${charset2.toString(16)})`);
              console.log(`Encoding flags: 0x${flags.toString(16).padStart(2, '0')} (${flags})`);
              console.log(`Compile caps length: ${compileLen} bytes\n`);

              // Extract compile caps
              const compileCaps = ttcPayload.slice(offset + 7, offset + 7 + compileLen);
              console.log(`Compile capabilities (hex): ${compileCaps.toString('hex').match(/.{1,2}/g).join(' ')}`);
              console.log(`\nCompile capabilities (indexed - non-zero only):`);
              for (let j = 0; j < compileCaps.length; j++) {
                if (compileCaps[j] !== 0) {
                  console.log(`  [${j.toString().padStart(2)}] = 0x${compileCaps[j].toString(16).padStart(2, '0')} (${compileCaps[j].toString().padStart(3)})`);
                }
              }

              // Extract runtime caps
              const runtimeOffset = offset + 7 + compileLen;
              const runtimeLen = ttcPayload[runtimeOffset];
              const runtimeCaps = ttcPayload.slice(runtimeOffset + 1, runtimeOffset + 1 + runtimeLen);

              console.log(`\nRuntime caps length: ${runtimeLen} bytes`);
              console.log(`Runtime capabilities (hex): ${runtimeCaps.toString('hex').match(/.{1,2}/g).join(' ')}`);
              console.log(`\nRuntime capabilities (indexed - non-zero only):`);
              for (let j = 0; j < runtimeCaps.length; j++) {
                if (runtimeCaps[j] !== 0) {
                  console.log(`  [${j.toString().padStart(2)}] = 0x${runtimeCaps[j].toString(16).padStart(2, '0')} (${runtimeCaps[j].toString().padStart(3)})`);
                }
              }

              // Show full message hex dump
              console.log(`\n=== FULL DATA TYPES MESSAGE (first 150 bytes) ===\n`);
              const fullMsg = ttcPayload.slice(offset, offset + 150);
              for (let j = 0; j < fullMsg.length; j += 16) {
                const chunk = fullMsg.slice(j, j + 16);
                const hexStr = chunk.toString('hex').match(/.{1,2}/g).join(' ').padEnd(48);
                const asciiStr = Array.from(chunk).map(b =>
                  (b >= 32 && b < 127) ? String.fromCharCode(b) : '.'
                ).join('');
                console.log(`${j.toString(16).padStart(4, '0')}: ${hexStr} ${asciiStr}`);
              }

              break;
            }
          }
        }

        break;
      }
    }

  } catch (err) {
    console.error('Error:', err.message);
  }
}

findDataTypesNeg();
