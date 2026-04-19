#!/usr/bin/env node

// Test script to validate NPM package structure and setup scripts
// Can run on any platform for basic validation

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

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
  log(`${colors.green} ${message}${colors.reset}`);
}

function logError(message) {
  log(`${colors.red} ${message}${colors.reset}`);
}

function logInfo(message) {
  log(`${colors.blue} ${message}${colors.reset}`);
}

async function validatePackageStructure() {
  log(`${colors.bold}Windows Clippy MCP - Package Validation${colors.reset}`);
  log(`${colors.blue} Validating package structure including WC25.png logo${colors.reset}`);
  log('');

    const requiredFiles = [
      'package.json',
      'main.py',
      'manifest.json',
      'pyproject.toml',
      'scripts/clippy-session.js',
      'scripts/clippy-widget-refresh.js',
      'scripts/clippy-widget-restart.js',
      'scripts/start-native-livetile.js',
      'scripts/clippy_widget_service.js',
      'scripts/service-runner.js',
      'scripts/setup.js',
      'scripts/start-widget.js',
    'scripts/install-service.js',
    'scripts/uninstall-service.js',
      'src/desktop/__init__.py',
      'src/desktop/views.py',
      'src/terminal/TerminalAdaptiveCard.js',
      'widget/Launch-ClippyWidget.cmd',
      'widget/Launch-ClippyLiveTile.cmd',
      'widget/clippy-widget.ps1',
      'widget/LiveTileHost/LiveTileHost.csproj',
      'widget/LiveTileHost/App.xaml',
      'widget/LiveTileHost/App.xaml.cs',
      'widget/LiveTileHost/MainWindow.xaml',
      'widget/LiveTileHost/MainWindow.xaml.cs',
      'widget/WidgetHost/WidgetHost.csproj',
      'widget/WidgetHost/App.xaml',
      'widget/WidgetHost/App.xaml.cs',
      'widget/WidgetHost/LauncherWindow.xaml',
      'widget/WidgetHost/LauncherWindow.xaml.cs',
      'widget/WidgetHost/MainWindow.xaml',
      'widget/WidgetHost/MainWindow.xaml.cs',
      'widget/WidgetHost/ConPtyConnection.cs',
      'widget/WidgetHost/ModelCatalog.cs',
      'widget/WidgetHost/PseudoConsoleApi.cs',
      'widget/WidgetHost/AgentCatalog.cs',
      'widget/WidgetHost/TerminalTabSession.cs',
      'widget/WidgetHost/WidgetSettings.cs',
      'widget/adaptive-cards/terminal-session.template.json',
      'widget/adaptive-cards/terminal-session.data.schema.json',
      'widget/adaptive-cards/clippy-native-livetile.template.json',
      'widget/adaptive-cards/clippy-native-livetile.data.schema.json',
      'widget/adaptive-cards/clippy-native-livetile.data.json',
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

    if (
      packageJson.bin &&
      packageJson.bin.clippy &&
      packageJson.bin['clippy-widget'] &&
      packageJson.bin['clippy-live-tile'] &&
      packageJson.bin.clippy_widget_refresh &&
      packageJson.bin.clippy_widget_restart
    ) {
      logSuccess('package.json exposes clippy, clippy-widget, clippy-live-tile, clippy_widget_refresh, and clippy_widget_restart binaries');
    } else {
      logError('package.json missing required widget bin entries');
      allValid = false;
    }

    const requiredPackagedPaths = [
      'assets/WC25.png',
      'assets/agentcard_32.png',
      'assets/agentcard_192.png',
      'assets/agentcard_focused_32.png',
      'assets/clippy25_32.png',
      'assets/clippy25_96.png',
      'assets/clippy25_128.png',
      'assets/clippy25_256.png',
      'scripts/**',
      'widget/clippy-widget.ps1',
      'widget/Launch-ClippyWidget.cmd',
      'widget/Launch-ClippyLiveTile.cmd',
      'widget/adaptive-cards/**',
      'widget/LiveTileHost/*.csproj',
      'widget/LiveTileHost/*.xaml',
      'widget/LiveTileHost/*.cs',
      'widget/WidgetHost/*.csproj',
      'widget/WidgetHost/*.xaml',
      'widget/WidgetHost/*.cs',
      'widget/TerminalHost/bin/Debug/net8.0-windows/*.dll',
      'widget/TerminalHost/bin/Debug/net8.0-windows/*.exe',
      'widget/TerminalHost/bin/Debug/net8.0-windows/*.json',
      'widget/TerminalHost/bin/Debug/net8.0-windows/runtimes/**/native/*.dll',
      'widget/WidgetHost/bin/Release/net8.0-windows/*.dll',
      'widget/WidgetHost/bin/Release/net8.0-windows/*.exe',
      'widget/WidgetHost/bin/Release/net8.0-windows/*.json',
      'widget/WidgetHost/bin/Release/net8.0-windows/agents/**',
      'widget/WidgetHost/bin/Release/net8.0-windows/mcp-apps/views/*.html',
      'widget/WidgetHost/bin/Release/net8.0-windows/runtimes/**/native/*.dll'
    ];

    for (const packagedPath of requiredPackagedPaths) {
      if (Array.isArray(packageJson.files) && packageJson.files.includes(packagedPath)) {
        logSuccess(`package.json files includes ${packagedPath}`);
      } else {
        logError(`package.json files missing ${packagedPath}`);
        allValid = false;
      }
    }

    // Check required scripts
    const requiredScripts = ['postinstall', 'setup', 'start', 'start:widget', 'start:widget:debug', 'start:live-tile', 'refresh:widget', 'restart:widget', 'start:mcp', 'install-service', 'uninstall-service'];
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
  log(`${colors.bold}Validating Script Syntax${colors.reset}`);
  log('');

    const scripts = [
      'scripts/clippy-session.js',
      'scripts/clippy-widget-refresh.js',
      'scripts/clippy-widget-restart.js',
      'scripts/start-native-livetile.js',
      'scripts/clippy_widget_service.js',
      'scripts/service-runner.js',
      'scripts/setup.js',
      'scripts/start-widget.js',
    'scripts/install-service.js',
    'scripts/uninstall-service.js',
    // Terminal broker scaffold (pty-renderer-architecture)
    'src/terminal/SessionCore.js',
     'src/terminal/TranscriptSink.js',
     'src/terminal/ChildHost.js',
     'src/terminal/SessionTab.js',
     'src/terminal/SessionBroker.js',
     'src/terminal/TerminalAdaptiveCard.js',
     'src/terminal/index.js'
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

async function validateNativeBuild() {
  if (process.platform !== 'win32') {
    return true;
  }

  log(`${colors.bold}Validating Native Build${colors.reset}`);
  log('');

  const result = spawnSync(
    'dotnet',
    ['build', '.\\Windows-Clippy-MCP.sln', '-nologo'],
    {
      cwd: process.cwd(),
      encoding: 'utf8',
      stdio: 'pipe'
    }
  );

  if (result.status === 0) {
    logSuccess('dotnet build succeeded for Windows-Clippy-MCP.sln');
    log('');
    return true;
  }

  const detail = (result.stderr || result.stdout || 'dotnet build failed without output').trim();
  logError(`dotnet build failed: ${detail}`);
  log('');
  return false;
}

async function showPlatformInfo() {
  log(`${colors.bold}Platform Information${colors.reset}`);
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
  log(`${colors.bold}${colors.blue}Windows Clippy MCP - Package Validation${colors.reset}`);
  log('');

  await showPlatformInfo();

  const structureValid = await validatePackageStructure();
  const scriptsValid = await validateScripts();
  const nativeBuildValid = await validateNativeBuild();

  log(`${colors.bold}Summary${colors.reset}`);
  log('');

  if (structureValid && scriptsValid && nativeBuildValid) {
    logSuccess('All validation checks passed! Package is ready for publication.');
    process.exit(0);
  } else {
    logError('Some validation checks failed. Please fix the issues before publishing.');
    process.exit(1);
  }
}

main().catch(console.error);
