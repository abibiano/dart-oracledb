// Extract and analyze protocol message from node batch
import fs from 'fs';

const nodeBytes = fs.readFileSync('node_ttc_batch.bin');
const dartBytes = fs.readFileSync('dart_ttc_batch.bin');

// Extract protocol message (first message in batch)
const nodeProtocolLen = nodeBytes[0];
const dartProtocolLen = dartBytes[0];

console.log(`Node protocol message length: ${nodeProtocolLen} bytes`);
console.log(`Dart protocol message length: ${dartProtocolLen} bytes`);
console.log(`Difference: ${nodeProtocolLen - dartProtocolLen} bytes\n`);

// Extract the protocol messages
const nodeProtocol = nodeBytes.slice(0, nodeProtocolLen);
const dartProtocol = dartBytes.slice(0, dartProtocolLen);

console.log('Node protocol message:');
console.log(nodeProtocol.toString('hex').match(/.{1,2}/g).join(' '));
console.log('');

console.log('Dart protocol message:');
console.log(dartProtocol.toString('hex').match(/.{1,2}/g).join(' '));
console.log('');

// Parse structure
console.log('=== Node Protocol Message Structure ===');
console.log(`[0] Length: ${nodeProtocol[0]} (0x${nodeProtocol[0].toString(16)})`);
console.log(`[1] Type: ${nodeProtocol[1]}`);
console.log(`[2-6] Header: ${Array.from(nodeProtocol.slice(2, 7)).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);

// Find driver name (should be after header)
let driverStart = 7;
let driverEnd = driverStart;
while (driverEnd < nodeProtocol.length && nodeProtocol[driverEnd] !== 0) {
  driverEnd++;
}
const nodeDriver = nodeProtocol.slice(driverStart, driverEnd).toString('utf8');
console.log(`[7-${driverEnd-1}] Driver: "${nodeDriver}"`);
console.log(`[${driverEnd}] Null terminator: 0x${nodeProtocol[driverEnd].toString(16)}`);

// Remaining bytes are padding
const nodePadding = nodeProtocol.slice(driverEnd + 1);
console.log(`[${driverEnd+1}-${nodeProtocol.length-1}] Padding (${nodePadding.length} bytes): ${Array.from(nodePadding).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);

console.log('\n=== Dart Protocol Message Structure ===');
console.log(`[0] Length: ${dartProtocol[0]} (0x${dartProtocol[0].toString(16)})`);
console.log(`[1] Type: ${dartProtocol[1]}`);
console.log(`[2-6] Header: ${Array.from(dartProtocol.slice(2, 7)).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);

driverStart = 7;
driverEnd = driverStart;
while (driverEnd < dartProtocol.length && dartProtocol[driverEnd] !== 0) {
  driverEnd++;
}
const dartDriver = dartProtocol.slice(driverStart, driverEnd).toString('utf8');
console.log(`[7-${driverEnd-1}] Driver: "${dartDriver}"`);
console.log(`[${driverEnd}] Null terminator: 0x${dartProtocol[driverEnd].toString(16)}`);

const dartPadding = dartProtocol.slice(driverEnd + 1);
console.log(`[${driverEnd+1}-${dartProtocol.length-1}] Padding (${dartPadding.length} bytes): ${Array.from(dartPadding).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);

console.log(`\n=== Analysis ===`);
console.log(`Node driver length: ${nodeDriver.length} chars`);
console.log(`Dart driver length: ${dartDriver.length} chars`);
console.log(`Node padding: ${nodePadding.length} bytes`);
console.log(`Dart padding: ${dartPadding.length} bytes`);
