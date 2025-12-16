// Compare just the AUTH_PHASE_ONE message
import fs from 'fs';

const dartBytes = fs.readFileSync('dart_ttc_batch.bin');
const nodeBytes = fs.readFileSync('node_ttc_batch.bin');

// AUTH_PHASE_ONE starts after protocol (34) + data types (2608) = offset 2642
const AUTH_OFFSET = 34 + 2608;

const dartAuth = dartBytes.slice(AUTH_OFFSET);
const nodeAuth = nodeBytes.slice(AUTH_OFFSET);

console.log(`Dart AUTH_PHASE_ONE: ${dartAuth.length} bytes`);
console.log(`Node AUTH_PHASE_ONE: ${nodeAuth.length} bytes`);
console.log(`Difference: ${dartAuth.length - nodeAuth.length} bytes\n`);

console.log('=== First 50 bytes comparison ===\n');
console.log('Dart:', dartAuth.slice(0, 50).toString('hex').match(/.{1,2}/g).join(' '));
console.log('Node:', nodeAuth.slice(0, 50).toString('hex').match(/.{1,2}/g).join(' '));

// Find differences
console.log('\n=== Byte-by-byte differences (first 50 bytes) ===\n');
const compareLength = Math.min(50, dartAuth.length, nodeAuth.length);
for (let i = 0; i < compareLength; i++) {
  if (dartAuth[i] !== nodeAuth[i]) {
    console.log(`Offset ${i}: Dart=0x${dartAuth[i].toString(16).padStart(2, '0')} Node=0x${nodeAuth[i].toString(16).padStart(2, '0')}`);
  }
}

// Show full AUTH messages
console.log('\n=== Full Dart AUTH_PHASE_ONE ===');
console.log(dartAuth.toString('hex').match(/.{1,32}/g).join('\n'));

console.log('\n=== Full Node AUTH_PHASE_ONE ===');
console.log(nodeAuth.toString('hex').match(/.{1,32}/g).join('\n'));
