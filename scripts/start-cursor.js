#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const packageDir = path.resolve(__dirname, '..');
const cursorScriptPath = path.join(packageDir, 'widget', 'clippy-cursor.ps1');

function ensureFileExists(filePath, label) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
}

function parseArguments(rawArgs) {
  const options = {
    debug: false,
    passthrough: []
  };

  for (const arg of rawArgs) {
    if (arg === '--debug' || arg === '--foreground') {
      options.debug = true;
      continue;
    }
    options.passthrough.push(arg);
  }

  return options;
}

function launchCursor(options) {
  const args = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    cursorScriptPath,
    '-Standalone',
    ...options.passthrough
  ];

  const child = spawn('pwsh.exe', args, {
    cwd: packageDir,
    detached: !options.debug,
    stdio: options.debug ? 'inherit' : 'ignore',
    windowsHide: !options.debug
  });

  if (!options.debug) {
    child.unref();
  }

  return child;
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  ensureFileExists(cursorScriptPath, 'Clippy Cursor script');

  const child = launchCursor(options);
  if (options.debug) {
    child.on('error', (error) => {
      console.error(`ERROR: Failed to launch Clippy Cursor: ${error.message}`);
      process.exit(1);
    });
    child.on('exit', (code) => {
      process.exit(code ?? 0);
    });
    return;
  }

  console.log(`Started Clippy Cursor Mode (PID ${child.pid}).`);
  console.log('Right-click anywhere for Clippy Click context, or use the widget Cursor Mode menu to restore defaults.');
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}

module.exports = {
  parseArguments,
  launchCursor
};
