// Runs bin/plan for the triggering event and exposes its targets and origs as outputs.
module.exports = async ({ context, core, exec }) => {
  let args;
  if (context.eventName === 'workflow_dispatch') {
    const { series, distros, test } = context.payload.inputs;
    if (!/^[a-z0-9.-]+$/.test(series)) throw new Error(`invalid series: ${series}`);
    args = [`builds/${series}.json`];
    if (distros) args.unshift('--distros', distros);
    if (test === true || test === 'true') args.unshift('--test');
  } else {
    args = ['--since', context.payload.before];
  }

  const { stdout } = await exec.getExecOutput('bin/plan', args);
  const plan = JSON.parse(stdout);
  core.setOutput('targets', JSON.stringify(plan.targets));
  core.setOutput('origs', JSON.stringify(plan.origs));
};
