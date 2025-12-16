// Convert node-oracledb dataTypes to Dart format
const constants = require('./reference/node-oracledb/lib/thin/protocol/constants.js');
const fs = require('fs');

// Read the dataType.js file
const dataTypeContent = fs.readFileSync('./reference/node-oracledb/lib/thin/protocol/messages/dataType.js', 'utf8');

// Extract the dataTypes array
const match = dataTypeContent.match(/const dataTypes = \[([\s\S]*?)\];/);
if (!match) {
  console.error('Could not find dataTypes array');
  process.exit(1);
}

const dataTypesText = match[1];

// Parse each line and convert to numeric values
const lines = dataTypesText.split('\n');
const dartEntries = [];

for (const line of lines) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('//')) continue;

  // Match pattern: [constants.NAME1, constants.NAME2, constants.NAME3]
  const arrayMatch = trimmed.match(/\[constants\.(TNS_\w+),\s*constants\.(TNS_\w+),\s*constants\.(TNS_\w+)\]/);
  if (arrayMatch) {
    const [, name1, name2, name3] = arrayMatch;
    const val1 = constants[name1];
    const val2 = constants[name2];
    const val3 = constants[name3];

    if (val1 !== undefined && val2 !== undefined && val3 !== undefined) {
      // Format comment from the first constant name
      const comment = name1.replace('TNS_DATA_TYPE_', '').toLowerCase();
      dartEntries.push(`  [${val1}, ${val2}, ${val3}], // ${comment}`);
    }
  }
}

// Generate Dart code
const dartCode = `  static final List<List<int>> _dataTypes = [\n${dartEntries.join('\n')}\n  ];`;

console.log(dartCode);
console.log(`\n// Total entries: ${dartEntries.length}`);
