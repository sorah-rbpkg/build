// Records the nightly packages whose every arch passed smoke in sorah-rbpkg/dockerfiles' nightly.json, a push that
// builds their images. Distros that failed keep their previous entry.
const fs = require('fs');

const owner = 'sorah-rbpkg';
const repo = 'dockerfiles';
const branch = 'master';
const file = 'nightly.json';

function sortKeys(value) {
  if (Array.isArray(value) || value === null || typeof value !== 'object') return value;
  return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sortKeys(value[k])]));
}

module.exports = async ({ github, context, core }) => {
  const targets = JSON.parse(process.env.TARGETS);
  // smoke uploads an empty file named after the artifact it passed.
  const passed = new Set(fs.existsSync(process.env.SMOKE_DIR) ? fs.readdirSync(process.env.SMOKE_DIR) : []);

  const distros = new Map();
  for (const target of targets) {
    const key = `${target.series}/${target.distro}`;
    if (!distros.has(key)) distros.set(key, { target, artifacts: {} });
    distros.get(key).artifacts[target.arch] = target.artifact;
  }
  const updates = [...distros.values()].filter(({ target, artifacts }) => {
    const ok = Object.values(artifacts).every((a) => passed.has(a));
    if (!ok) core.warning(`${target.source} ${target.distro} did not pass smoke on every arch; keeping its previous nightly`);
    return ok;
  });
  if (updates.length === 0) {
    core.info('nothing to roll');
    return;
  }

  const versions = [...new Map(updates.map(({ target }) => [target.source, target.upstream_version])).entries()];
  const subject = versions.length === 1
    ? `roll nightly ${versions[0][0]} ${versions[0][1]}`
    : `roll nightly ${versions.map(([source]) => source).join(', ').replace(/, ([^,]+)$/, ' & $1')}`;
  const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  const message = `${subject}\n\n${versions.map(([source, version]) => `- ${source} ${version}`).join('\n')}\n\nBuilt by ${runUrl}\n`;

  // Retried from a fresh read when master moves under us; the ref is only ever fast-forwarded.
  for (let attempt = 1; ; attempt++) {
    const { data: ref } = await github.rest.git.getRef({ owner, repo, ref: `heads/${branch}` });
    const parent = ref.object.sha;

    let current = {};
    try {
      const { data } = await github.rest.repos.getContent({ owner, repo, path: file, ref: parent });
      current = JSON.parse(Buffer.from(data.content, 'base64').toString('utf8'));
    } catch (e) {
      if (e.status !== 404) throw e;
    }

    const next = structuredClone(current);
    for (const { target, artifacts } of updates) {
      next[target.series] ??= {};
      next[target.series][target.distro] = {
        version: target.deb_version,
        revision: target.revision,
        run_id: context.runId,
        artifacts,
      };
    }
    const content = `${JSON.stringify(sortKeys(next), null, 2)}\n`;
    if (content === `${JSON.stringify(sortKeys(current), null, 2)}\n`) {
      core.info(`${file} already has these nightlies`);
      return;
    }

    const { data: commit } = await github.rest.git.getCommit({ owner, repo, commit_sha: parent });
    const { data: tree } = await github.rest.git.createTree({
      owner, repo, base_tree: commit.tree.sha,
      tree: [{ path: file, mode: '100644', type: 'blob', content }],
    });
    // Left without author and committer, so GitHub signs it as the app the token belongs to.
    const { data: created } = await github.rest.git.createCommit({ owner, repo, message, tree: tree.sha, parents: [parent] });
    try {
      await github.rest.git.updateRef({ owner, repo, ref: `heads/${branch}`, sha: created.sha, force: false });
      core.info(`pushed ${created.sha} to ${owner}/${repo} ${branch}: ${subject}`);
      return;
    } catch (e) {
      if (e.status !== 422 || attempt >= 5) throw e;
      core.info(`${branch} moved; retrying (${attempt})`);
    }
  }
};
