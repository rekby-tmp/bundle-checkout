'use strict';
const fs = require('fs');
const path = require('path');
const { run, inputEnv } = require('./run');

const input = (name) => (process.env[`INPUT_${name.toUpperCase()}`] || '').trim();

// Same guard as actions/checkout: pull_request_target and workflow_run run with the base
// repository's secrets, so fork code is checked out there only on explicit opt-in.
function assertSafePrCheckout() {
  if (input('allow-unsafe-pr-checkout').toUpperCase() === 'TRUE') return;
  const event = process.env.GITHUB_EVENT_NAME;
  if (event !== 'pull_request_target' && event !== 'workflow_run') return;
  const workflowRepo = (process.env.GITHUB_REPOSITORY || '').toLowerCase();
  const repo = (input('repository') || workflowRepo).toLowerCase();
  const ref = input('ref');
  if (repo === workflowRepo && !ref) return;

  let payload = {};
  try {
    payload = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  } catch {
    return;
  }
  const baseRepoId = payload.repository && payload.repository.id;
  let headRepo;
  const shas = [];
  if (event === 'pull_request_target') {
    const pr = payload.pull_request || {};
    headRepo = pr.head && pr.head.repo;
    shas.push(pr.head && pr.head.sha, pr.merge_commit_sha);
  } else {
    const wr = payload.workflow_run || {};
    if (!String(wr.event || '').startsWith('pull_request')) return;
    headRepo = wr.head_repository;
    shas.push(wr.head_commit && wr.head_commit.id);
    // For a workflow_run triggered by pull_request_target, head_sha is the base commit.
    if (wr.event !== 'pull_request_target') shas.push(wr.head_sha);
  }
  if (!headRepo || typeof headRepo.id !== 'number' || headRepo.id === baseRepoId) return;

  const targetsFork =
    repo === String(headRepo.full_name || '').toLowerCase() ||
    /^refs\/pull\/\d+\/(head|merge)$/.test(ref) ||
    shas.filter(Boolean).map((s) => s.toLowerCase()).includes(ref.toLowerCase());
  if (targetsFork) {
    console.log(
      `::error::bundle-checkout: refusing to check out fork pull request code in a ${event} workflow. ` +
        'Such workflows run with the base repository token and secrets. ' +
        'Set allow-unsafe-pr-checkout: true on this step only after reviewing the risk.',
    );
    process.exit(1);
  }
}

// As in actions/checkout, the repository must stay under the workspace: the destination is
// cleaned before the checkout.
function resolvePath() {
  const workspace = path.resolve(process.env.GITHUB_WORKSPACE || process.cwd());
  const target = path.resolve(workspace, input('path'));
  if (target !== workspace && !target.startsWith(workspace + path.sep)) {
    console.log(`::error::bundle-checkout: repository path '${target}' is not under '${workspace}'`);
    process.exit(1);
  }
  return target;
}

assertSafePrCheckout();
const env = inputEnv();
env.INPUT_PATH = resolvePath();
process.exitCode = run('checkout.sh', env);
