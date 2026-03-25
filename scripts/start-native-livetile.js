#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const packageDir = path.resolve(__dirname, '..');
const projectPath = path.join(packageDir, 'widget', 'LiveTileHost', 'LiveTileHost.csproj');
const defaultDataPath = path.join(packageDir, 'widget', 'adaptive-cards', 'clippy-native-livetile.data.json');
const defaultTemplatePath = path.join(packageDir, 'widget', 'adaptive-cards', 'clippy-native-livetile.template.json');
const defaultSchemaPath = path.join(packageDir, 'widget', 'adaptive-cards', 'clippy-native-livetile.data.schema.json');

function ensureFileExists(filePath, label) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
}

function parseArguments(rawArgs) {
  const options = {
    configuration: 'Debug',
    build: false,
    dataPath: defaultDataPath,
    templatePath: defaultTemplatePath,
    schemaPath: defaultSchemaPath,
    passthrough: []
  };

  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];

    if (arg === '--release') {
      options.configuration = 'Release';
      continue;
    }

    if (arg === '--no-build') {
      options.build = false;
      continue;
    }

    if (arg === '--build') {
      options.build = true;
      continue;
    }

    if (arg === '--configuration') {
      const value = rawArgs[index + 1];
      if (!value) {
        throw new Error('--configuration requires a value.');
      }
      options.configuration = value;
      index += 1;
      continue;
    }

    if (arg === '--data' || arg === '--template' || arg === '--schema' || arg === '--title' || arg === '--left' || arg === '--top' || arg === '--no-topmost') {
      if (arg === '--data' || arg === '--template' || arg === '--schema' || arg === '--title' || arg === '--left' || arg === '--top') {
        const value = rawArgs[index + 1];
        if (!value) {
          throw new Error(`${arg} requires a value.`);
        }
        if (arg === '--data') {
          options.dataPath = path.resolve(packageDir, value);
          options.passthrough.push(arg, options.dataPath);
        } else if (arg === '--template') {
          options.templatePath = path.resolve(packageDir, value);
          options.passthrough.push(arg, options.templatePath);
        } else if (arg === '--schema') {
          options.schemaPath = path.resolve(packageDir, value);
          options.passthrough.push(arg, options.schemaPath);
        } else {
          options.passthrough.push(arg, value);
        }
        index += 1;
        continue;
      }

      options.passthrough.push(arg);
      continue;
    }

    options.passthrough.push(arg);
  }

  if (!options.passthrough.includes('--data')) {
    options.passthrough.push('--data', options.dataPath);
  }
  if (!options.passthrough.includes('--template')) {
    options.passthrough.push('--template', options.templatePath);
  }
  if (!options.passthrough.includes('--schema')) {
    options.passthrough.push('--schema', options.schemaPath);
  }

  return options;
}

function buildLiveTileHost(configuration) {
  const result = spawnSync(
    'dotnet',
    ['build', projectPath, '-c', configuration, '-nologo'],
    {
      cwd: packageDir,
      stdio: 'inherit',
      windowsHide: true
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`dotnet build failed for LiveTileHost (${configuration}).`);
  }
}

function getExePath(configuration) {
  return path.join(
    packageDir,
    'widget',
    'LiveTileHost',
    'bin',
    configuration,
    'net8.0-windows',
    'LiveTileHost.exe'
  );
}

function launchLiveTile(exePath, args) {
  const child = spawn(exePath, args, {
    cwd: packageDir,
    detached: true,
    stdio: 'ignore',
    windowsHide: false
  });

  child.unref();
  return child.pid;
}

function main() {
  const options = parseArguments(process.argv.slice(2));

  ensureFileExists(projectPath, 'LiveTileHost project');
  ensureFileExists(options.dataPath, 'Live tile data payload');
  ensureFileExists(options.templatePath, 'Live tile template');
  ensureFileExists(options.schemaPath, 'Live tile data schema');

  const exePath = getExePath(options.configuration);
  if (options.build || !fs.existsSync(exePath)) {
    buildLiveTileHost(options.configuration);
  }

  ensureFileExists(exePath, 'LiveTileHost executable');

  const pid = launchLiveTile(exePath, options.passthrough);
  console.log(`Started Windows Clippy native live tile (PID ${pid}).`);
  console.log(`Data: ${options.dataPath}`);
  console.log(`Template: ${options.templatePath}`);
  console.log(`Schema: ${options.schemaPath}`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}
