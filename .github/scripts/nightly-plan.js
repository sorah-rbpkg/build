// Runs bin/plan-nightly for the triggering event and exposes its targets and origs as outputs.
// The orig tarballs are saved to orig/.
module.exports = async ({ context, core, exec }) => {
  const args = ['--out', 'orig'];
  if (context.eventName === 'workflow_dispatch') {
    const { series, force } = context.payload.inputs;
    if (force === true || force === 'true') args.push('--force');
    if (series) {
      if (!/^ruby[0-9.]+$/.test(series)) throw new Error(`invalid series: ${series}`);
      args.push(`gen/builds/${series}.json`);
    }
  }

  const { stdout } = await exec.getExecOutput('bin/plan-nightly', args);
  const plan = JSON.parse(stdout);
  core.setOutput('targets', JSON.stringify(plan.targets));
  core.setOutput('origs', JSON.stringify(plan.origs));
};
