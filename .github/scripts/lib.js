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

module.exports = { initSigningRepo, authArgs, remoteTagCommit, assetName };
