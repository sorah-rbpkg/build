// Tags the staged commit with gitsign and fast-forwards the dist branch of the release repository.
const { initSigningRepo, authArgs, remoteTagCommit } = require('./lib.js');

module.exports = async ({ core, exec }) => {
  const target = JSON.parse(process.env.TARGET);
  const stageSha = process.env.STAGE_SHA;
  const releaseUrl = `https://github.com/${target.release_repository}.git`;
  const { dir, git } = await initSigningRepo(exec, 'release');

  // By SHA rather than by stage branch, which a later run may have moved.
  await git('fetch', '--no-tags', `https://github.com/${process.env.GITHUB_REPOSITORY}.git`, stageSha);

  // A new dist branch is created by the push below, which fails if one has appeared meanwhile.
  if (!target.new_dist) {
    await git('fetch', '--no-tags', `https://github.com/${target.repository}.git`,
      `+refs/heads/${target.dist_branch}:refs/remotes/origin/${target.dist_branch}`);
    const ancestor = await exec.exec('git', ['-C', dir, 'merge-base', '--is-ancestor',
      `refs/remotes/origin/${target.dist_branch}`, stageSha], { ignoreReturnCode: true });
    if (ancestor !== 0) {
      throw new Error(`${target.dist_branch} on ${target.repository} has moved since ${stageSha} was staged`);
    }
  }

  // Test runs overwrite whatever an earlier test run pushed.
  if (!target.test) {
    const tagged = await remoteTagCommit(exec, releaseUrl, target.release_tag);
    if (tagged && tagged !== stageSha) {
      throw new Error(`${target.release_tag} already exists at ${tagged}, which another run has released`);
    }
    if (tagged) {
      core.info(`${target.release_tag} already points at ${stageSha}`);
      return;
    }
  }

  await git('tag', '-s', '-f', '-m', `${target.source} Debian release ${target.deb_version}`, target.release_tag, stageSha);
  await git(...authArgs(core, process.env.RELEASE_TOKEN), 'push', '--atomic', ...(target.test ? ['--force'] : []), releaseUrl,
    `${stageSha}:refs/heads/${target.release_dist_branch}`, `refs/tags/${target.release_tag}`);
};
