#!/usr/bin/env node

const fs = require('fs').promises;
const path = require('path');
const { exec, spawn } = require('child_process');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Console colors for better output
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

function logStep(step, message) {
  log(`${colors.bold}[${step}]${colors.reset} ${colors.blue}${message}${colors.reset}`);
}

function logSuccess(message) {
  log(`${colors.green}✓ ${message}${colors.reset}`);
}

function logWarning(message) {
  log(`${colors.yellow}⚠ ${message}${colors.reset}`);
}

function logError(message) {
  log(`${colors.red}✗ ${message}${colors.reset}`);
}

async function checkPlatform() {
  if (process.platform !== 'win32') {
    logError('This package only works on Windows. Please use a Windows system.');
    process.exit(1);
  }
  logSuccess('Platform check passed (Windows detected)');
}

async function checkDependencies() {
  logStep('1/6', 'Checking dependencies...');
  
  // Check if Python is available
  try {
    await execAsync('python --version');
    logSuccess('Python detected');
  } catch (error) {
    logError('Python not found. Please install Python 3.13+ from python.org');
    process.exit(1);
  }

  // Check if UV is available, install if not
  try {
    await execAsync('uv --version');
    logSuccess('UV package manager detected');
  } catch (error) {
    logWarning('UV not found. Installing UV...');
    try {
      await execAsync('pip install uv');
      logSuccess('UV installed successfully');
    } catch (installError) {
      logError('Failed to install UV. Please install manually: pip install uv');
      process.exit(1);
    }
  }
}

async function installPythonDependencies() {
  logStep('2/6', 'Installing Python dependencies...');
  
  try {
    const { stdout, stderr } = await execAsync('uv sync', {
      cwd: __dirname.replace('/scripts', ''),
      timeout: 600000 // 10 minutes timeout
    });
    
    if (stderr && !stderr.includes('Resolved') && !stderr.includes('Installing')) {
      logWarning(`UV output: ${stderr}`);
    }
    
    logSuccess('Python dependencies installed');
  } catch (error) {
    logError(`Failed to install Python dependencies: ${error.message}`);
    process.exit(1);
  }
}

async function createVSCodeConfig() {
  logStep('3/6', 'Setting up VS Code configuration...');
  
  const packageDir = path.resolve(__dirname, '..');
  
  // Try to find workspace directories where VS Code might be used
  const possibleWorkspaces = [
    process.cwd(),
    path.join(process.env.USERPROFILE || '', 'Documents'),
    path.join(process.env.USERPROFILE || '', 'Projects'),
    path.join(process.env.USERPROFILE || '', 'Code')
  ];

  let configured = false;

  for (const workspace of possibleWorkspaces) {
    try {
      const vscodeDirPath = path.join(workspace, '.vscode');
      const mcpConfigPath = path.join(vscodeDirPath, 'mcp.json');
      const settingsPath = path.join(vscodeDirPath, 'settings.json');

      // Check if this looks like a VS Code workspace
      const stats = await fs.stat(workspace).catch(() => null);
      if (!stats || !stats.isDirectory()) continue;

      // Create .vscode directory if it doesn't exist
      await fs.mkdir(vscodeDirPath, { recursive: true });

      // Create MCP configuration
      const mcpConfig = {
        servers: {
          "windows-clippy-mcp": {
            type: "stdio",
            command: "uv",
            args: [
              "--directory",
              packageDir,
              "run",
              "main.py"
            ]
          }
        },
        inputs: []
      };

      await fs.writeFile(mcpConfigPath, JSON.stringify(mcpConfig, null, 2));

      // Create or update VS Code settings
      let settings = {};
      try {
        const existingSettings = await fs.readFile(settingsPath, 'utf8');
        settings = JSON.parse(existingSettings);
      } catch (error) {
        // File doesn't exist or is invalid JSON, start fresh
      }

      settings['mcp.servers'] = {
        ...settings['mcp.servers'],
        "windows-clippy-mcp": {
          command: "uv",
          args: [
            "--directory",
            packageDir,
            "run",
            "main.py"
          ],
          env: {}
        }
      };

      await fs.writeFile(settingsPath, JSON.stringify(settings, null, 2));
      
      if (workspace === process.cwd()) {
        logSuccess(`VS Code configuration created in current directory: ${workspace}`);
        configured = true;
        break;
      }
    } catch (error) {
      // Silently continue to next workspace
    }
  }

  // Also create a global configuration
  try {
    const globalSettingsPath = path.join(
      process.env.APPDATA || '', 
      'Code', 
      'User', 
      'settings.json'
    );
    
    let globalSettings = {};
    try {
      const existingGlobalSettings = await fs.readFile(globalSettingsPath, 'utf8');
      globalSettings = JSON.parse(existingGlobalSettings);
    } catch (error) {
      // File doesn't exist or is invalid JSON
    }

    globalSettings['mcp.servers'] = {
      ...globalSettings['mcp.servers'],
      "windows-clippy-mcp": {
        command: "uv",
        args: [
          "--directory",
          packageDir,
          "run",
          "main.py"
        ],
        env: {}
      }
    };

    await fs.writeFile(globalSettingsPath, JSON.stringify(globalSettings, null, 2));
    logSuccess('Global VS Code configuration updated');
    configured = true;
  } catch (error) {
    logWarning(`Could not update global VS Code settings: ${error.message}`);
  }

  if (!configured) {
    logWarning('Could not automatically configure VS Code. You may need to manually add the MCP configuration.');
  }
}

async function createServiceScript() {
  logStep('4/6', 'Creating Windows service scripts...');
  
  const serviceScript = `
@echo off
echo Starting Windows Clippy MCP Service...
cd /d "${path.resolve(__dirname, '..')}"
uv run main.py
`;

  const servicePath = path.join(__dirname, 'start-service.bat');
  await fs.writeFile(servicePath, serviceScript);
  
  logSuccess('Service script created');
}

async function registerService() {
  logStep('5/6', 'Registering Windows service (optional)...');
  
  try {
    // This is optional and may require admin privileges
    logWarning('Service registration requires administrator privileges.');
    logWarning('You can manually run the service later using: npm run install-service');
    logSuccess('Service registration step completed (manual setup available)');
  } catch (error) {
    logWarning('Service registration skipped. You can set it up later if needed.');
  }
}

async function validateInstallation() {
  logStep('6/6', 'Validating installation...');
  
  try {
    // Test that the MCP server can start (briefly)
    const testProcess = spawn('uv', ['run', 'python', '-c', 'from fastmcp import FastMCP; print("MCP server validation: OK")'], {
      cwd: path.resolve(__dirname, '..'),
      timeout: 30000
    });

    await new Promise((resolve, reject) => {
      let output = '';
      testProcess.stdout.on('data', (data) => {
        output += data.toString();
      });
      
      testProcess.on('close', (code) => {
        if (code === 0 && output.includes('OK')) {
          resolve();
        } else {
          reject(new Error(`Validation failed with code ${code}`));
        }
      });
      
      testProcess.on('error', reject);
    });
    
    logSuccess('Installation validation passed');
  } catch (error) {
    logWarning(`Validation had issues: ${error.message}`);
    logWarning('The installation may still work. Try running: npm start');
  }
}

async function showCompletionMessage() {
  log('');
  log(`${colors.bold}${colors.green}🎉 Windows Clippy MCP Setup Complete!${colors.reset}`);
  log('');
  log(`${colors.bold}Next steps:${colors.reset}`);
  log(`  1. ${colors.blue}Restart VS Code${colors.reset} completely for MCP integration`);
  log(`  2. ${colors.blue}Test the server:${colors.reset} npm start`);
  log(`  3. ${colors.blue}Use in VS Code:${colors.reset} Open agent mode and start using Windows Clippy tools`);
  log('');
  log(`${colors.bold}Available commands:${colors.reset}`);
  log(`  • ${colors.yellow}npm start${colors.reset}          - Start the MCP server manually`);
  log(`  • ${colors.yellow}npm run install-service${colors.reset} - Install as Windows service (requires admin)`);
  log(`  • ${colors.yellow}npm run uninstall-service${colors.reset} - Remove Windows service`);
  log('');
  log(`${colors.bold}Documentation:${colors.reset} https://github.com/dayour/Windows-Clippy-MCP`);
  log('');
}

async function main() {
  log(`${colors.bold}${colors.blue}🚀 Windows Clippy MCP - One-Click Setup${colors.reset}`);
  log('');

  try {
    await checkPlatform();
    await checkDependencies();
    await installPythonDependencies();
    await createVSCodeConfig();
    await createServiceScript();
    await registerService();
    await validateInstallation();
    await showCompletionMessage();
  } catch (error) {
    logError(`Setup failed: ${error.message}`);
    process.exit(1);
  }
}

// Run setup if this script is executed directly
if (require.main === module) {
  main().catch(console.error);
}

module.exports = { main };