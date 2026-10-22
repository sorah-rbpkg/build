const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// Initializes a scratch repository whose commits and tags gitsign signs with this workflow's identity.
async function initSigningRepo(exec, name) {
  const dir = path.join(process.env.RUNNER_TEMP, name);
  await exec.exec('git', ['init', '-q', dir]);
  const config = {
    'user.name': 'github-actions[bot]',
    'user.email': '41898282+github-actions[bot]@users.noreply.github.com',
    'gpg.format': 'x509',
    'gpg.x509.program': 'gitsign',
  };
  for (const [key, value] of Object.entries(config)) {
    await exec.exec('git', ['-C', dir, 'config', key, value]);
  }
  const git = (...args) => exec.exec('git', ['-C', dir, ...args]);
  return { dir, git };
}

// git -c arguments that authenticate pushes to github.com with the token.
function authArgs(core, token) {
  const auth = Buffer.from(`x-access-token:${token}`).toString('base64');
  core.setSecret(auth);
  return ['-c', `http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}`];
}

// The commit a remote tag points at, or null when the tag does not exist.
async function remoteTagCommit(exec, url, tag) {
  const { stdout } = await exec.getExecOutput('git', ['ls-remote', url, `refs/tags/${tag}`, `refs/tags/${tag}^{}`], { silent: true });
  const lines = stdout.trim().split('\n').filter(Boolean).map((line) => line.split('\t'));
  const peeled = lines.find(([, ref]) => ref.endsWith('^{}'));
  return (peeled || lines[0] || [null])[0];
}

// GitHub replaces characters such as "~" in release asset names with ".".
function assetName(file) {
  return path.basename(file).replace(/[^A-Za-z0-9._+-]/g, '.');
}

const UPLOAD_ATTEMPTS = 3;

// Uploads a file to a release unless an identical asset is there already.
// A same-named asset from an interrupted or earlier upload is replaced.
async function uploadAsset(github, core, { owner, repo, releaseId, file }) {
  const name = assetName(file);
  const data = fs.readFileSync(file);
  const digest = `sha256:${crypto.createHash('sha256').update(data).digest('hex')}`;
  for (let attempt = 1; ; attempt++) {
    try {
      const assets = await github.paginate(github.rest.repos.listReleaseAssets, { owner, repo, release_id: releaseId, per_page: 100 });
      const existing = assets.find((a) => a.name === name);
      if (existing && existing.state === 'uploaded' && existing.digest === digest) {
        core.info(`${name} is already uploaded`);
        return;
      }
      if (existing) await github.rest.repos.deleteReleaseAsset({ owner, repo, asset_id: existing.id });
      await github.rest.repos.uploadReleaseAsset({
        owner, repo, release_id: releaseId, name, data,
        headers: { 'content-type': 'application/octet-stream', 'content-length': data.length },
      });
      core.info(`uploaded ${name}`);
      return;
    } catch (e) {
      if (attempt >= UPLOAD_ATTEMPTS) throw e;
      core.warning(`uploading ${name} failed (attempt ${attempt}): ${e.message}`);
      await new Promise((resolve) => setTimeout(resolve, attempt * 10_000));
    }
  }
}

module.exports = { initSigningRepo, authArgs, remoteTagCommit, assetName, uploadAsset };
