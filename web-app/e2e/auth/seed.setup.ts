import { test as setup } from '@playwright/test';
import { execSync } from 'node:child_process';
import path from 'node:path';

const WEB_APP = path.resolve(__dirname, '..', '..');

// Runs after the five sign-in setups (which create the User rows) and before
// every test project. One Rails boot, ~10s. Prints the task's own log lines
// so a failure says which step refused and why.
setup('prepare the three e2e accounts and their data', async () => {
  setup.setTimeout(180_000);
  try {
    const out = execSync('bin/rails e2e:prepare', {
      cwd: WEB_APP,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    console.log(out);
  } catch (error) {
    const failed = error as { stdout?: string; stderr?: string };
    throw new Error(`bin/rails e2e:prepare failed:\n${failed.stdout ?? ''}\n${failed.stderr ?? ''}`);
  }
});
