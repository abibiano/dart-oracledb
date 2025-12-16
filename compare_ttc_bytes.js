// Compare dart and node TTC batches byte-by-byte
import fs from 'fs';

const dartBytes = fs.readFileSync('dart_ttc_batch.bin');
const nodeBytes = fs.readFileSync('node_ttc_batch.bin');

console.log(`Dart TTC batch: ${dartBytes.length} bytes`);
console.log(`Node TTC batch: ${nodeBytes.length} bytes`);

if (dartBytes.length !== nodeBytes.length) {
  console.error('\n❌ LENGTH MISMATCH!');
  process.exit(1);
}

console.log('\n✓ Same length (2780 bytes)');
console.log('\nSearching for byte differences...\n');

let diffCount = 0;
const diffs = [];

for (let i = 0; i < dartBytes.length; i++) {
  if (dartBytes[i] !== nodeBytes[i]) {
    diffCount++;
    diffs.push({
      offset: i,
      dart: dartBytes[i],
      node: nodeBytes[i]
    });
  }
}

if (diffCount === 0) {
  console.log('✓✓✓ PERFECT MATCH! All bytes identical!');
  process.exit(0);
}

console.log(`Found ${diffCount} byte differences:\n`);

// Show all differences with context
for (const diff of diffs) {
  const offset = diff.offset;
  console.log(`Offset ${offset} (0x${offset.toString(16).padStart(4, '0').toUpperCase()}):`);
  console.log(`  Dart: 0x${diff.dart.toString(16).padStart(2, '0').toUpperCase()} (${diff.dart})`);
  console.log(`  Node: 0x${diff.node.toString(16).padStart(2, '0').toUpperCase()} (${diff.node})`);

  // Show 8 bytes of context around the difference
  const start = Math.max(0, offset - 4);
  const end = Math.min(dartBytes.length, offset + 4);

  const dartContext = Array.from(dartBytes.slice(start, end))
    .map((b, idx) => {
      const hex = b.toString(16).padStart(2, '0').toUpperCase();
      return (start + idx === offset) ? `[${hex}]` : hex;
    })
    .join(' ');

  const nodeContext = Array.from(nodeBytes.slice(start, end))
    .map((b, idx) => {
      const hex = b.toString(16).padStart(2, '0').toUpperCase();
      return (start + idx === offset) ? `[${hex}]` : hex;
    })
    .join(' ');

  console.log(`  Dart context: ${dartContext}`);
  console.log(`  Node context: ${nodeContext}`);
  console.log('');
}

// Analyze which section the differences are in
console.log('\n=== Section Analysis ===');
console.log('Protocol message: bytes 0-26 (27 bytes)');
console.log('Data types message: bytes 27-2634 (2608 bytes)');
console.log('AUTH_PHASE_ONE: bytes 2635-2779 (145 bytes)');
console.log('');

const protocolDiffs = diffs.filter(d => d.offset < 27);
const dataTypesDiffs = diffs.filter(d => d.offset >= 27 && d.offset < 2635);
const authDiffs = diffs.filter(d => d.offset >= 2635);

console.log(`Protocol message differences: ${protocolDiffs.length}`);
console.log(`Data types differences: ${dataTypesDiffs.length}`);
console.log(`AUTH_PHASE_ONE differences: ${authDiffs.length}`);
