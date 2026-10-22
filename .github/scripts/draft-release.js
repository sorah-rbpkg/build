// Creates or updates the draft release of the target's tag with every file in DIR.
// The body follows the layout sorah-deb-release writes, which bin/publish parses back.
const fs = require('fs');
const path = require('path');
const { uploadAsset } = require('./lib.js');

// Written into the release body by bin/publish.
const RESIGNED_MARKER = '<!-- resigned-by:';

function attestationSection(dir) {
  const lines = ['### Attestations', ''];
  for (const arch of fs.readdirSync(dir).sort()) {
    const url = fs.readFileSync(path.join(dir, arch), 'utf8').trim();
    if (!/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/attestations\/\d+$/.test(url)) {
      throw new Error(`unexpected attestation url for ${arch}: ${url}`);
    }
    lines.push(`- ${arch}: ${url}`);
  }
  return lines.join('\n');
}

function releaseBody(files, attestations) {
  const dscs = files.filter((f) => f.endsWith('.dsc'));
  if (dscs.length !== 1) throw new Error(`expected one .dsc, got ${dscs.join(', ')}`);

  const body = ['### Changes', ''];
  for (const changes of files.filter((f) => f.endsWith('.changes')).sort()) {
    const arch = changes.match(/_([a-z0-9]+)\.changes$/)[1];
    body.push(`#### ${arch}`, '', '```', fs.readFileSync(changes, 'utf8').trimEnd(), '```', '');
  }
  body.push('### dsc', '', '```', fs.readFileSync(dscs[0], 'utf8').trimEnd(), '```', '', attestations);
  return body.join('\n');
}

module.exports = async ({ github, core }) => {
  const target = JSON.parse(process.env.TARGET);
  const [owner, repo] = target.release_repository.split('/');
  const tag = target.release_tag;
  const files = fs.readdirSync(process.env.DIR).sort().map((name) => path.join(process.env.DIR, name));
  const body = releaseBody(files, attestationSection(process.env.ATTESTATION_DIR));

  // Fails when release.js has not pushed the tag, rather than letting the release create one.
  await github.rest.git.getRef({ owner, repo, ref: `tags/${tag}` });

  const releases = await github.paginate(github.rest.repos.listReleases, { owner, repo, per_page: 100 });
  let release = releases.find((r) => r.tag_name === tag);
  const resigned = release && (release.body || '').includes(RESIGNED_MARKER);
  // A test run replaces what an earlier one finished, and resumes what it left unfinished.
  if (release && target.test && (resigned || !release.draft)) {
    await github.rest.repos.deleteRelease({ owner, repo, release_id: release.id });
    release = undefined;
  }
  if (release && !release.draft) throw new Error(`${tag} is already published on ${target.release_repository}`);
  if (resigned && release) {
    throw new Error(`${tag} has been re-signed by bin/publish; uploading would replace its signed files`);
  }

  if (release) {
    await github.rest.repos.updateRelease({ owner, repo, release_id: release.id, body });
  } else {
    ({ data: release } = await github.rest.repos.createRelease({ owner, repo, tag_name: tag, name: tag, body, draft: true }));
  }

  for (const file of files) {
    await uploadAsset(github, core, { owner, repo, releaseId: release.id, file });
  }
  core.info(release.html_url);
};
