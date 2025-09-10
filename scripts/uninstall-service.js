#!/usr/bin/env node

const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs').promises;
const path = require('path');

const execAsync = promisify(exec);

// Console colors
const colors = {
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
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

function logWarning(message) {
  log(`${colors.yellow}⚠ ${message}${colors.reset}`);
}

async function uninstallService() {
  if (process.platform !== 'win32') {
    logError('Windows service uninstallation only works on Windows.');
    process.exit(1);
  }

  log(`${colors.bold}${colors.blue}🗑️  Uninstalling Windows Clippy MCP Service${colors.reset}`);
  log('');

  const serviceName = 'WindowsClippyMCP';

  try {
    // Check if service exists
    try {
      await execAsync(`sc query "${serviceName}"`);
    } catch (error) {
      logWarning(`Service '${serviceName}' not found or already uninstalled.`);
      return;
    }

    // Stop the service if it's running
    try {
      await execAsync(`sc stop "${serviceName}"`);
      logSuccess(`Service '${serviceName}' stopped`);
      
      // Wait a moment for the service to fully stop
      await new Promise(resolve => setTimeout(resolve, 2000));
    } catch (error) {
      logWarning(`Service '${serviceName}' was not running or could not be stopped`);
    }

    // Delete the service
    await execAsync(`sc delete "${serviceName}"`);
    logSuccess(`Service '${serviceName}' removed successfully`);

    // Clean up service runner script
    const scriptPath = path.join(__dirname, 'service-runner.js');
    try {
      await fs.unlink(scriptPath);
      logSuccess('Service runner script cleaned up');
    } catch (error) {
      // File might not exist, that's OK
    }

    log('');
    log(`${colors.bold}${colors.green}Service uninstalled successfully!${colors.reset}`);
    log('');
    log(`${colors.bold}You can still use Windows Clippy MCP by running:${colors.reset}`);
    log(`  • ${colors.yellow}npm start${colors.reset} - Start the MCP server manually`);
    log('');

  } catch (error) {
    logError(`Failed to uninstall service: ${error.message}`);
    log('');
    log(`${colors.yellow}Note: Service uninstallation requires administrator privileges.${colors.reset}`);
    log(`${colors.yellow}Please run this command as Administrator.${colors.reset}`);
    process.exit(1);
  }
}

if (require.main === module) {
  uninstallService().catch(console.error);
}

module.exports = { uninstallService };