#!/usr/bin/env node

const { parseCliArguments, refreshWidgets } = require('./start-widget');

async function main() {
  try {
    const options = parseCliArguments(process.argv.slice(2));
    const result = await refreshWidgets(options);

    if (options.debug) {
      console.warn('WARNING: --debug has no effect for clippy_widget_refresh.');
    }

    if (result.reusedExistingWidget) {
      console.log(result.launcherKind === 'native'
        ? 'Windows Clippy native widget is already running.'
        : 'Windows Clippy widget dashboard is already running.');
      if (result.widgetPid) {
        console.log(`Widget host PID: ${result.widgetPid}`);
      }
      if (result.widgetUrl) {
        console.log(`Dashboard URL: ${result.widgetUrl}`);
      }
    } else if (result.usedFallbackLaunch) {
      console.log('No running widget hosts were found. Queued a fresh widget launch.');
    } else {
      console.log(`Refreshed ${result.launchCount} widget instance(s).`);
    }

    if (result.stoppedWidgetPids.length > 0) {
      console.log(`Stopped widget host PIDs: ${result.stoppedWidgetPids.join(', ')}`);
    }

    if (result.queuedRequests.length > 0) {
      console.log(result.launcherKind === 'native'
        ? `Launched widget host PID(s): ${result.queuedRequests.join(', ')}`
        : `Queued widget request(s): ${result.queuedRequests.join(', ')}`);
    }
    console.log(`${result.launcherKind === 'native' ? 'Launch log' : 'Service log'}: ${result.logPath || result.serviceLogPath}`);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}
