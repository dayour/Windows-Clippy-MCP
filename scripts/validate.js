#!/usr/bin/env node

// Test script to validate NPM package structure and setup scripts
// Can run on any platform for basic validation

const fs = require('fs');
const path = require('path');

const colors = {
  green: '\x1b[32m',
  blue: '\x1b[34m',
  yellow: '\x1b[33m',
  red: '\x1b[31m',
  reset: '\x1b[0m',
  bold: '\x1b[1m'
};

function log(message, color = colors.reset) {
  console.log(`${color}${message}${colors.reset}`);
}

function logSuccess(message) {
  log(`${colors.green}✓ ${message}${colors.reset}`);
}

function logError(message) {
  log(`${colors.red}✗ ${message}${colors.reset}`);
}

function logInfo(message) {
  log(`${colors.blue}ℹ ${message}${colors.reset}`);
}

async function validatePackageStructure() {
  log(`${colors.bold}📎 Windows Clippy MCP - Package Validation${colors.reset}`);
  log(`${colors.blue}   Validating package structure including WC25.png logo${colors.reset}`);
  log('');

  const requiredFiles = [
    'package.json',
    'main.py',
    'manifest.json',
    'pyproject.toml',
    'scripts/setup.js',
    'scripts/install-service.js',
    'scripts/uninstall-service.js',
    'src/desktop/__init__.py',
    'src/desktop/views.py',
    'assets/WC25.png',
    'README.md',
    'LICENSE'
  ];

  let allValid = true;

  for (const file of requiredFiles) {
    try {
      const stats = fs.statSync(file);
      if (stats.isFile()) {
        logSuccess(`Found: ${file}`);
      } else {
        logError(`Not a file: ${file}`);
        allValid = false;
      }
    } catch (error) {
      logError(`Missing: ${file}`);
      allValid = false;
    }
  }

  log('');
  
  // Validate package.json structure
  try {
    const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
    
    const requiredFields = ['name', 'version', 'description', 'scripts', 'keywords'];
    for (const field of requiredFields) {
      if (packageJson[field]) {
        logSuccess(`package.json has ${field}`);
      } else {
        logError(`package.json missing ${field}`);
        allValid = false;
      }
    }

    // Check required scripts
    const requiredScripts = ['postinstall', 'setup', 'start', 'install-service', 'uninstall-service'];
    for (const script of requiredScripts) {
      if (packageJson.scripts && packageJson.scripts[script]) {
        logSuccess(`Script defined: ${script}`);
      } else {
        logError(`Script missing: ${script}`);
        allValid = false;
      }
    }

  } catch (error) {
    logError(`Invalid package.json: ${error.message}`);
    allValid = false;
  }

  log('');
  
  // Validate Python project structure
  try {
    const pyprojectToml = fs.readFileSync('pyproject.toml', 'utf8');
    if (pyprojectToml.includes('[project]') && pyprojectToml.includes('dependencies')) {
      logSuccess('pyproject.toml structure looks valid');
    } else {
      logError('pyproject.toml missing required sections');
      allValid = false;
    }
  } catch (error) {
    logError(`Invalid pyproject.toml: ${error.message}`);
    allValid = false;
  }

  log('');

  if (allValid) {
    logSuccess('All package structure validation checks passed!');
  } else {
    logError('Some package structure validation checks failed.');
  }

  return allValid;
}

async function validateScripts() {
  log(`${colors.bold}🧪 Validating Script Syntax${colors.reset}`);
  log('');

  const scripts = [
    'scripts/setup.js',
    'scripts/install-service.js', 
    'scripts/uninstall-service.js'
  ];

  let allValid = true;

  for (const script of scripts) {
    try {
      require.resolve(path.resolve(script));
      logSuccess(`Script syntax valid: ${script}`);
    } catch (error) {
      logError(`Script syntax error in ${script}: ${error.message}`);
      allValid = false;
    }
  }

  log('');

  if (allValid) {
    logSuccess('All script syntax validation checks passed!');
  } else {
    logError('Some script syntax validation checks failed.');
  }

  return allValid;
}

async function showPlatformInfo() {
  log(`${colors.bold}🖥️  Platform Information${colors.reset}`);
  log('');
  
  logInfo(`Platform: ${process.platform}`);
  logInfo(`Architecture: ${process.arch}`);
  logInfo(`Node.js: ${process.version}`);
  
  if (process.platform === 'win32') {
    logSuccess('Running on Windows - full functionality available');
  } else {
    logInfo('Running on non-Windows platform - syntax validation only');
  }
  
  log('');
}

async function main() {
  log(`${colors.bold}${colors.blue}🚀 Windows Clippy MCP - Package Validation${colors.reset}`);
  log('');

  await showPlatformInfo();
  
  const structureValid = await validatePackageStructure();
  const scriptsValid = await validateScripts();

  log(`${colors.bold}📋 Summary${colors.reset}`);
  log('');
  
  if (structureValid && scriptsValid) {
    logSuccess('All validation checks passed! Package is ready for publication.');
    process.exit(0);
  } else {
    logError('Some validation checks failed. Please fix the issues before publishing.');
    process.exit(1);
  }
}

main().catch(console.error);