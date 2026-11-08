import { test, expect } from '@playwright/test';
import { Server } from 'http';
import { OauthClient, registerClient, startCallbackServer } from '../../helpers/oauth-client';

// Signed-out half of the MCP authorize page: the prompt, the round trip through
// the sign-in modal, and Approve ending on the client's callback. Matched by the
// `books` project (no storageState). The member and non-member halves are in
// books/member/ and books/account/.
test.describe('OAuth authorize page, signed out', () => {
  let client: OauthClient;
  let callback: Server;

  test.beforeAll(async ({ request }) => {
    client = await registerClient(request, 43101);
    callback = await startCallbackServer(43101);
  });

  test.afterAll(() => {
    callback.close();
  });

  test('asks the visitor to sign in, then shows the same request and Approve reaches the client', async ({ page }) => {
    await page.goto(client.authorizeUrl);

    await expect(page.getByRole('heading', { level: 1, name: 'Sign in to connect an app' })).toBeVisible();
    await expect(page.getByTestId('oauth-redirect-host')).toHaveText('127.0.0.1:43101');
    await expect(page.getByTestId('oauth-approve')).toHaveCount(0);

    await page.getByRole('main').getByRole('button', { name: 'Sign in' }).click();
    const modal = page.locator('#login_modal');
    await expect(modal).toBeVisible();
    const emailStep = modal.locator('[data-authentication-target="emailStep"]');
    await emailStep.getByPlaceholder('Email address').fill(process.env.PLAYWRIGHT_MEMBER_EMAIL!);
    await emailStep.getByRole('button', { name: 'Continue' }).click();
    const password = modal.getByPlaceholder('Password');
    await expect(password).toBeVisible();
    await password.fill(process.env.PLAYWRIGHT_MEMBER_PASSWORD!);
    await modal.getByRole('button', { name: 'Sign In' }).click();

    // The widget reloads the current URL: the approval screen for the same request.
    await expect(page.getByTestId('oauth-approve')).toBeVisible({ timeout: 20000 });
    await expect(page.locator('form input[name="state"]').first()).toHaveValue(client.state);
    await expect(page.locator('form input[name="redirect_uri"]').first()).toHaveValue(client.redirectUri);

    await page.getByTestId('oauth-approve').click();

    await page.waitForURL(client.callbackPattern);
    const landed = new URL(page.url());
    expect(landed.searchParams.get('state')).toBe(client.state);
    expect(landed.searchParams.get('code')).toBeTruthy();
    expect(landed.searchParams.get('error')).toBeNull();
  });

  test('an unregistered redirect address is refused, not redirected to', async ({ page }) => {
    const url = client.authorizeUrl.replace(encodeURIComponent(client.redirectUri), encodeURIComponent('https://evil.example/callback'));
    const response = await page.goto(url);

    expect(response!.status()).toBe(400);
    await expect(page).toHaveURL(/\/oauth\/authorize/);
    await expect(page.getByRole('heading', { level: 1, name: 'This app cannot be connected' })).toBeVisible();
  });
});
