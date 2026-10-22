// Merges the series commit into the distro's dist branch and stages the result as a branch of this repository.
const fs = require('fs');
const path = require('path');
const { initSigningRepo, authArgs } = require('./lib.js');

module.exports = async ({ core, exec }) => {
  const target = JSON.parse(process.env.TARGET);
  const { dir, git } = await initSigningRepo(exec, 'merge');

  // A full fetch, because the first push of a stage branch carries the whole history.
  await git('fetch', '--no-tags', `https://github.com/${target.repository}.git`,
    `+refs/heads/${target.dist_branch}:refs/remotes/origin/${target.dist_branch}`, target.commit);
  await git('checkout', '-q', '--detach', `refs/remotes/origin/${target.dist_branch}`);
  await git('-c', 'commit.gpgsign=true', 'merge', '--no-ff',
    '-m', `Merge branch '${target.master}' into ${target.dist_branch}`, target.commit);

  const head = fs.readFileSync(path.join(dir, 'debian/changelog'), 'utf8').split('\n', 1)[0];
  const version = head.match(/^\S+ \(([^)]+)\)/)[1].replace('~dist', `~${target.distro}`);
  if (version !== target.deb_version) {
    throw new Error(`debian/changelog after merge has ${version}, expected ${target.deb_version}`);
  }

  await git(...authArgs(core, process.env.GH_TOKEN), 'push', '--force',
    `https://github.com/${process.env.GITHUB_REPOSITORY}.git`, `HEAD:refs/heads/${target.stage_branch}`);

  const { stdout } = await exec.getExecOutput('git', ['-C', dir, 'rev-parse', 'HEAD']);
  core.setOutput('sha', stdout.trim());
};
