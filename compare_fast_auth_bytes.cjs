// Capture first 200 bytes of FAST_AUTH from node-oracledb
const oracledb = require('oracledb');
const net = require('net');
const fs = require('fs');

let packet2 = null;
let count = 0;

const orig = net.Socket.prototype.write;
net.Socket.prototype.write = function(data, ...args) {
  count++;
  if (count === 2) {
    packet2 = data;
    // Extract TTC payload (skip 10-byte TNS header for large SDU)
    const ttcPayload = data.slice(10);
    console.log('Node FAST_AUTH TTC payload:');
    console.log('Length:', ttcPayload.length, 'bytes');
    console.log('\nFirst 100 bytes:');
    console.log(ttcPayload.slice(0, 100).toString('hex').match(/.{1,2}/g).join(' '));
    
    // Save to file
    fs.writeFileSync('node_fast_auth.bin', ttcPayload);
    console.log('\nSaved to node_fast_auth.bin');
  }
  return orig.call(this, data, ...args);
};

(async () => {
  try {
    const conn = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });
    await conn.close();
  } catch (e) {
    // Ignore
  }
})();
