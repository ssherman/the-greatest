import { test, expect } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';
import { expectSignedIn, expectSignedOut, firebaseUserCount } from '../../../support/sign-in-state';
import { ageCache } from '../../../support/state-requests';

// The Rails session is the single source of truth for sign-in state; Firebase's
// IndexedDB is not in storage state, so each test signs in for real.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Sign-in state (books)', () => {
  test('every indicator agrees after sign in and reload', async ({ page }) => {
    await signIn(page, credentials('USER'));
    await page.goto('/');
    await expectSignedIn(page);

    const response = await page.goto('/my/lists');
    expect(response?.status()).toBe(200);
    expect(new URL(page.url()).pathname).toBe('/my/lists');
  });

  test('sign out flips every indicator and the old session cookie is rejected', async ({ page, context }) => {
    await signIn(page, credentials('USER'));
    await page.goto('/');
    await expectSignedIn(page);

    const old = (await context.cookies()).find((cookie) => cookie.name === 'tg_session');
    expect(old).toBeDefined();

    await page.locator('#navbar_login_button').click();
    await expectSignedOut(page);

    await context.addCookies([old!]);
    const response = await page.request.get('/user_list_state', { headers: { Accept: 'application/json' } });
    expect(response.status()).toBe(401);
  });

  test('Firebase forgetting the user leaves the visitor signed in', async ({ page }) => {
    await signIn(page, credentials('USER'));
    await page.goto('/');
    await expectSignedIn(page);

    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const request = indexedDB.deleteDatabase('firebaseLocalStorageDb');
          request.onsuccess = () => resolve();
          request.onerror = () => resolve();
          request.onblocked = () => resolve();
        })
    );
    await page.reload();
    await expectSignedIn(page);
  });

  test('the server forgetting the user signs the browser out everywhere', async ({ page, context }) => {
    await signIn(page, credentials('USER'));
    await page.goto('/');
    await expectSignedIn(page);
    expect(await firebaseUserCount(page)).toBeGreaterThan(0);

    await context.clearCookies({ name: 'tg_session' });
    // A page load only asks the server when its cached state is missing, an hour
    // old or flagged by the change marker. Age the entry so this reload is the
    // re-check that discovers the session is gone (the 401 is what signs out).
    await ageCache(page, 61 * 60 * 1000);
    await page.reload();
    await expectSignedOut(page);

    await page.locator('#navbar_login_button').click();
    await expect(page.locator('#login_modal')).toBeVisible();
    await expect.poll(() => firebaseUserCount(page), { timeout: 15_000 }).toBe(0);
  });

  test('a throttled /user_list_state with no cached state keeps the My link', async ({ page }) => {
    await signIn(page, credentials('USER'));
    await page.goto('/');
    await expectSignedIn(page);

    await page.route('**/user_list_state', (route) => route.fulfill({ status: 429, body: '' }));
    await page.evaluate(() => localStorage.removeItem('tg:user_list_state:books'));
    await page.reload();
    await expectSignedIn(page);
  });
});
