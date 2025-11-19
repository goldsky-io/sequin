#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const yaml = require('js-yaml');

// Read and parse the prod.yaml file
function readProdYaml() {
  try {
    const prodYamlPath = path.join(__dirname, 'prod.yaml');
    const fileContents = fs.readFileSync(prodYamlPath, 'utf8');
    return yaml.load(fileContents);
  } catch (error) {
    console.error('Error reading prod.yaml:', error.message);
    process.exit(1);
  }
}

// Create temporary YAML file for a chunk of sinks
function createTempYamlFile(sinks, chunkIndex) {
  const tempData = {
    sinks: sinks
  };

  const sinkNames = sinks.map(s => s.name).join('_');
  const tempFileName = `temp_chunk_${chunkIndex}_${sinkNames.substring(0, 50)}.yaml`;
  const tempFilePath = path.join(__dirname, tempFileName);

  try {
    const yamlContent = yaml.dump(tempData, { indent: 2 });
    fs.writeFileSync(tempFilePath, yamlContent, 'utf8');
    console.log(`Created temporary file: ${tempFileName}`);
    return tempFilePath;
  } catch (error) {
    console.error(`Error creating temporary file for chunk ${chunkIndex}:`, error.message);
    process.exit(1);
  }
}

// Run sequin command for a temporary file
function runSequinCommand(tempFilePath) {
  try {
    const command = `./cli/sequin --context self-hosted-prod config apply ${tempFilePath} --auto-approve`;
    console.log(`Running command: ${command}`);

    const output = execSync(command, {
      stdio: 'inherit',
      encoding: 'utf8'
    });

    console.log(`✅ Successfully applied ${path.basename(tempFilePath)}`);
  } catch (error) {
    console.error(`❌ Error running sequin command for ${path.basename(tempFilePath)}:`, error.message);
    process.exit(1);
  }
}

// Clean up temporary file
function cleanupTempFile(tempFilePath) {
  try {
    fs.unlinkSync(tempFilePath);
    console.log(`Cleaned up temporary file: ${path.basename(tempFilePath)}`);
  } catch (error) {
    console.error(`Warning: Could not clean up temporary file ${path.basename(tempFilePath)}:`, error.message);
  }
}

// Split array into chunks of specified size
function chunkArray(array, chunkSize) {
  const chunks = [];
  for (let i = 0; i < array.length; i += chunkSize) {
    chunks.push(array.slice(i, i + chunkSize));
  }
  return chunks;
}

// Main function
function main() {
  console.log('Starting sink processing in chunks of 5...\n');

  const prodConfig = readProdYaml();

  if (!prodConfig.sinks || !Array.isArray(prodConfig.sinks)) {
    console.error('No sinks array found in prod.yaml');
    process.exit(1);
  }

  const chunks = chunkArray(prodConfig.sinks, 5);
  console.log(`Found ${prodConfig.sinks.length} sinks to process in ${chunks.length} chunks\n`);

  for (let chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
    const chunk = chunks[chunkIndex];
    const chunkSinkNames = chunk.map(s => s.name).join(', ');

    console.log(`\n--- Processing chunk ${chunkIndex + 1}/${chunks.length} ---`);
    console.log(`Sinks in this chunk: ${chunkSinkNames}`);

    // Create temporary YAML file for this chunk
    const tempFilePath = createTempYamlFile(chunk, chunkIndex);

    // Run sequin command
    runSequinCommand(tempFilePath);

    // Clean up temporary file
    cleanupTempFile(tempFilePath);

    // Add a small delay between chunks
    if (chunkIndex < chunks.length - 1) {
      console.log('Waiting 2 seconds before next chunk...');
      // execSync('sleep 2');
    }
  }

  console.log('\n=== Summary ===');
  console.log(`Total sinks processed: ${prodConfig.sinks.length}`);
  console.log(`Total chunks processed: ${chunks.length}`);
  console.log('✅ All chunks processed successfully!');
}

// Run the script
if (require.main === module) {
  main();
}
