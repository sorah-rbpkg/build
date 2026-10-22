// Publishes the orig tarball as a release of this repository.
// The release stays a draft until the upload completes, so a rerun resumes it.
const { uploadAsset } = require('./lib.js');

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const env = process.env;
  const file = `out/${env.ORIG_NAME}`;

  const releases = await github.paginate(github.rest.repos.listReleases, { owner, repo, per_page: 100 });
  let release = releases.find((r) => r.tag_name === env.ORIG_RELEASE);
  if (release && !release.draft) throw new Error(`${env.ORIG_RELEASE} is already published`);
  if (!release) {
    ({ data: release } = await github.rest.repos.createRelease({
      owner, repo, tag_name: env.ORIG_RELEASE, target_commitish: context.sha, name: env.ORIG_NAME, draft: true,
      body: `Generated from ${env.REPOSITORY} ${env.UPSTREAM_TAG} (${env.UPSTREAM_COMMIT}). Attestation: ${env.ATTESTATION_URL}`,
    }));
  }

  await uploadAsset(github, core, { owner, repo, releaseId: release.id, file });
  await github.rest.repos.updateRelease({ owner, repo, release_id: release.id, draft: false, make_latest: 'false' });
};
