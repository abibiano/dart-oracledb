// Decode the actual structure of node's batched TTC
import fs from 'fs';

const batch = fs.readFileSync('node_ttc_batch.bin');

console.log('=== Analyzing Node TTC Batch Structure ===\n');
console.log(`Total batch size: ${batch.length} bytes\n`);

// Try to decode assuming length-prefixed messages
let offset = 0;
let msgNum = 1;

while (offset < batch.length) {
  const lengthByte = batch[offset];
  console.log(`\n--- Message ${msgNum} at offset ${offset} ---`);
  console.log(`Length byte: ${lengthByte} (0x${lengthByte.toString(16)})`);

  if (lengthByte === 0 || offset + lengthByte > batch.length) {
    console.log('Invalid length or end of batch');
    break;
  }

  const message = batch.slice(offset, offset + lengthByte);
  console.log(`Message bytes (${message.length}):`);
  console.log(message.toString('hex').match(/.{1,32}/g).join('\n'));

  // Try to identify message type
  const msgType = message[1]; // Assuming byte 1 is message type
  let typeName = 'Unknown';
  if (msgType === 1) typeName = 'PROTOCOL';
  else if (msgType === 2) typeName = 'DATA_TYPES';
  else if (msgType === 3) typeName = 'FUNCTION';

  console.log(`\nMessage type: ${msgType} (${typeName})`);

  // Extract string if it looks like protocol message
  if (msgType === 1) {
    // Find the driver name (starts after header, ends at null)
    let strStart = 7; // After length, type, version, terminator, and padding
    let strEnd = strStart;
    while (strEnd < message.length && message[strEnd] !== 0) {
      strEnd++;
    }
    const driverName = message.slice(strStart, strEnd).toString('utf8');
    console.log(`Driver name: "${driverName}"`);

    // Show trailing bytes after null
    const trailing = message.slice(strEnd + 1);
    console.log(`Trailing bytes after null (${trailing.length}): ${trailing.toString('hex').match(/.{1,2}/g).join(' ')}`);
  }

  offset += lengthByte;
  msgNum++;

  if (msgNum > 5) {
    console.log('\n... stopping after 5 messages');
    break;
  }
}

console.log(`\n\nProcessed ${offset} of ${batch.length} bytes`);
console.log(`Remaining: ${batch.length - offset} bytes`);
