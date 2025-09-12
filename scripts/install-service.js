#!/usr/bin/env node

const fs = require('fs').promises;
const path = require('path');
const { exec } = require('child_process');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Console colors
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

async function installService() {
  if (process.platform !== 'win32') {
    logError('Windows service installation only works on Windows.');
    process.exit(1);
  }

  log(`${colors.bold}${colors.blue}🔧 Installing Windows Clippy MCP as Windows Service${colors.reset}`);
  log('');

  try {
    // Create a more robust service script
    const serviceName = 'WindowsClippyMCP';
    const serviceDisplayName = 'Windows Clippy MCP Server';
    const serviceDescription = 'Windows Clippy MCP - AI assistant for Windows desktop automation';
    const packageDir = path.resolve(__dirname, '..');
    const scriptPath = path.join(packageDir, 'scripts', 'service-runner.js');

    // Create service runner script
    const serviceRunner = `
const { spawn } = require('child_process');
const path = require('path');

const packageDir = '${packageDir.replace(/\\/g, '\\\\')}';

function startMCPServer() {
  console.log('Starting Windows Clippy MCP Server...');
  
  const server = spawn('uv', ['run', 'main.py'], {
    cwd: packageDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: false
  });

  server.stdout.on('data', (data) => {
    console.log(\`MCP: \${data.toString()}\`);
  });

  server.stderr.on('data', (data) => {
    console.error(\`MCP Error: \${data.toString()}\`);
  });

  server.on('close', (code) => {
    console.log(\`MCP server exited with code \${code}\`);
    // Auto-restart after 5 seconds
    setTimeout(startMCPServer, 5000);
  });

  server.on('error', (error) => {
    console.error(\`MCP server error: \${error.message}\`);
    setTimeout(startMCPServer, 5000);
  });
}

// Start the server
startMCPServer();

// Keep the process alive
process.on('SIGINT', () => {
  console.log('Service stopping...');
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('Service stopping...');
  process.exit(0);
});
`;

    await fs.writeFile(scriptPath, serviceRunner);

    // Create Windows service using sc command
    const createCommand = `sc create "${serviceName}" binPath= "node \\"${scriptPath}\\"" DisplayName= "${serviceDisplayName}" Description= "${serviceDescription}" start= auto`;
    
    await execAsync(createCommand);
    logSuccess(`Service '${serviceName}' created successfully`);

    // Start the service
    await execAsync(`sc start "${serviceName}"`);
    logSuccess(`Service '${serviceName}' started successfully`);

    log('');
    log(`${colors.bold}Service installed and started!${colors.reset}`);
    log(`Service Name: ${serviceName}`);
    log(`Display Name: ${serviceDisplayName}`);
    log('');
    log(`${colors.bold}Service Management Commands:${colors.reset}`);
    log(`  • Start:   sc start "${serviceName}"`);
    log(`  • Stop:    sc stop "${serviceName}"`);
    log(`  • Status:  sc query "${serviceName}"`);
    log(`  • Remove:  npm run uninstall-service`);
    log('');

  } catch (error) {
    logError(`Failed to install service: ${error.message}`);
    log('');
    log(`${colors.yellow}Note: Service installation requires administrator privileges.${colors.reset}`);
    log(`${colors.yellow}Please run this command as Administrator.${colors.reset}`);
    process.exit(1);
  }
}

if (require.main === module) {
  installService().catch(console.error);
}

module.exports = { installService };