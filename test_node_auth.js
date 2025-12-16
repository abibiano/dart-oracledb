// Minimal node-oracledb authentication test for protocol capture
//
// Run with tcpdump to capture AUTH_PHASE_ONE:
// In terminal 1: sudo tcpdump -i lo0 -nn -XX port 1521 > node_capture.txt
// In terminal 2: node test_node_auth.js

import oracledb from 'oracledb';

// Thin mode is automatic if native client isn't available
// Just verify we're not trying to use thick mode
console.log('Using thin mode:', oracledb.thin);

async function testAuth() {
  let connection;

  try {
    console.log('Connecting to Oracle with node-oracledb thin mode...');

    connection = await oracledb.getConnection({
      user: 'system',
      password: 'testpassword',
      connectString: 'localhost:1521/FREEPDB1'
    });

    console.log('✓ Authentication successful!');

    // Execute a simple query to verify
    const result = await connection.execute('SELECT * FROM dual');
    console.log('✓ Query executed:', result.rows);

  } catch (err) {
    console.error('✗ Error:', err.message);
    console.error(err);
  } finally {
    if (connection) {
      await connection.close();
    }
  }
}

testAuth();
