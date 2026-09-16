import { test as setup, expect } from '@playwright/test';
import path from 'path';

// The MEMBER account. PLAYWRIGHT_ADMIN_EMAIL is deliberately a non-member
// (e2e/tests/books/account/membership.spec.ts depends on it), so members-only
// pages get their own account, comped by `bin/rails e2e:member`.
const authFile = path.join(__dirname, '..', '.auth', 'books-member.json');

setup.use({ baseURL: 'https://dev-new.thegreatestbooks.org' });

setup('authenticate as the member on books domain', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('button', { name: 'Login' }).click();

  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_MEMBER_EMAIL!);
  await modal.getByRole('button', { name: 'Continue' }).click();

  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(process.env.PLAYWRIGHT_MEMBER_PASSWORD!);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  // Same wait as books-auth.setup.ts: the Rails session cookie is set by the
  // JWT exchange that follows the Firebase sign-in, not by the click itself.
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(3000);

  await page.context().storageState({ path: authFile });
});
