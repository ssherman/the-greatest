import { test as setup, expect } from '@playwright/test';
import path from 'path';

const authFile = path.join(__dirname, '..', '.auth', 'games-user.json');

setup.use({ baseURL: 'https://dev.thegreatest.games' });

setup('authenticate as admin on games domain', async ({ page }) => {
  // Navigate to games homepage
  await page.goto('/');

  // Click the Login button in the navbar
  await page.getByRole('button', { name: 'Login' }).click();

  // Wait for the auth modal to open
  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  // Step 1: Enter email and click Continue
  await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
  await modal.getByRole('button', { name: 'Continue' }).click();

  // Step 2: Wait for password step, enter password, and submit
  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  // Wait for page reload and Firebase auth state propagation
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(3000);

  // Save storage state for reuse by all games test projects
  await page.context().storageState({ path: authFile });
});
