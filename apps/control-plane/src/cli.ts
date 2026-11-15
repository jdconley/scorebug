/**
 * Admin commands, run inside the control-plane container against its database:
 *
 *   docker compose exec control-plane node apps/control-plane/dist/cli.js setup-link
 *
 * See admin.ts for the commands.
 */
// node:sqlite is still flagged experimental on Node 22. Filter that one warning
// before loading it (hence the dynamic import) so admin output stays clean.
for (const listener of process.listeners('warning')) process.off('warning', listener);
process.on('warning', (warning) => {
  if (warning.name !== 'ExperimentalWarning')
    process.stderr.write(`${warning.name}: ${warning.message}\n`);
});

const { main } = await import('./admin.js');
try {
  await main(process.argv.slice(2));
} catch (error) {
  process.stderr.write(`error: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
