import { test, expect } from '@playwright/test';

// Guards the two halves of on-demand Firebase loading. Both are invisible to
// the Rails suite: nothing server-side knows which script tags the browser
// ended up fetching.
test.describe('Firebase loads on demand', () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test('an anonymous reader does not download the Firebase bundle', async ({ page }) => {
    const firebaseRequests: string[] = [];
    page.on('request', (request) => {
      if (request.url().includes('firebase-auth')) firebaseRequests.push(request.url());
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');

    expect(firebaseRequests).toHaveLength(0);
  });

  test('opening the login modal downloads the Firebase bundle', async ({ page }) => {
    await page.goto('/');
    await page.waitForLoadState('networkidle');

    const firebaseResponse = page.waitForResponse((response) =>
      response.url().includes('firebase-auth') && response.status() === 200
    );

    await page.getByRole('button', { name: 'Login' }).click();

    await firebaseResponse;
    await expect(page.locator('#login_modal')).toBeVisible();
  });
});
