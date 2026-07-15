import { test as setup, expect } from '@playwright/test';
import path from 'path';

const authFile = path.join(__dirname, '..', '.auth', 'books-user.json');

setup.use({ baseURL: 'https://dev-new.thegreatestbooks.org' });

setup('authenticate as admin on books domain', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('button', { name: 'Login' }).click();

  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
  await modal.getByRole('button', { name: 'Continue' }).click();

  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(3000);

  await page.context().storageState({ path: authFile });
});
