'use strict';
// Runs a bash script of the action. The action is written in bash; JavaScript is used only
// because the runner supports post steps for JavaScript actions alone.
const { spawnSync } = require('child_process');
const path = require('path');

function run(script, env) {
  const result = spawnSync('bash', [path.join(__dirname, '..', 'scripts', script)], {
    stdio: 'inherit',
    env,
  });
  if (result.error) {
    console.log(`::error::bundle-checkout: cannot run ${script}: ${result.error.message}`);
    return 1;
  }
  return result.status === null ? 1 : result.status;
}

// The runner passes the input "fetch-depth" as INPUT_FETCH-DEPTH, which bash cannot read.
function inputEnv() {
  const env = { ...process.env };
  for (const [key, value] of Object.entries(process.env)) {
    if (key.startsWith('INPUT_')) env[key.replace(/[- ]/g, '_')] = value;
  }
  return env;
}

module.exports = { run, inputEnv };
