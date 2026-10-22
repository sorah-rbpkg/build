// Creates or updates the draft release of the target's tag with every file in DIR.
// The body follows the layout sorah-deb-release writes, which bin/publish parses back.
const fs = require('fs');
const path = require('path');
const { assetName } = require('./lib.js');

// Written into the release body by bin/publish.
const RESIGNED_MARKER = '<!-- resigned-by:';

function releaseBody(files) {
  const dscs = files.filter((f) => f.endsWith('.dsc'));
  if (dscs.length !== 1) throw new Error(`expected one .dsc, got ${dscs.join(', ')}`);

  const body = ['### Changes', ''];
  for (const changes of files.filter((f) => f.endsWith('.changes')).sort()) {
    const arch = changes.match(/_([a-z0-9]+)\.changes$/)[1];
    body.push(`#### ${arch}`, '', '```', fs.readFileSync(changes, 'utf8').trimEnd(), '```', '');
  }
  body.push('### dsc', '', '```', fs.readFileSync(dscs[0], 'utf8').trimEnd(), '```');
  return body.join('\n');
}

module.exports = async ({ github, core }) => {
  const target = JSON.parse(process.env.TARGET);
  const [owner, repo] = target.release_repository.split('/');
  const tag = target.release_tag;
  const files = fs.readdirSync(process.env.DIR).sort().map((name) => path.join(process.env.DIR, name));
  const body = releaseBody(files);

  // Fails when release.js has not pushed the tag, rather than letting the release create one.
  await github.rest.git.getRef({ owner, repo, ref: `tags/${tag}` });

  const releases = await github.paginate(github.rest.repos.listReleases, { owner, repo, per_page: 100 });
  let release = releases.find((r) => r.tag_name === tag);
  if (release && target.test) {
    await github.rest.repos.deleteRelease({ owner, repo, release_id: release.id });
    release = undefined;
  }
  if (release && !release.draft) throw new Error(`${tag} is already published on ${target.release_repository}`);
  if (release && (release.body || '').includes(RESIGNED_MARKER)) {
    throw new Error(`${tag} has been re-signed by bin/publish; uploading would replace its signed files`);
  }

  if (release) {
    await github.rest.repos.updateRelease({ owner, repo, release_id: release.id, body });
  } else {
    ({ data: release } = await github.rest.repos.createRelease({ owner, repo, tag_name: tag, name: tag, body, draft: true }));
  }

  const assets = await github.paginate(github.rest.repos.listReleaseAssets, { owner, repo, release_id: release.id, per_page: 100 });
  for (const file of files) {
    const name = assetName(file);
    const existing = assets.find((a) => a.name === name);
    if (existing) await github.rest.repos.deleteReleaseAsset({ owner, repo, asset_id: existing.id });
    const data = fs.readFileSync(file);
    await github.rest.repos.uploadReleaseAsset({
      owner, repo, release_id: release.id, name, data,
      headers: { 'content-type': 'application/octet-stream', 'content-length': data.length },
    });
    core.info(`uploaded ${name}`);
  }
  core.info(release.html_url);
};
