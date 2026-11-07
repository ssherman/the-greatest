import { test, expect } from '@playwright/test';
import { Server } from 'http';
import { OauthClient, registerClient, startCallbackServer } from '../../../helpers/oauth-client';

// Matched by `books-member`: PLAYWRIGHT_MEMBER_EMAIL, signed in, with an active
// membership. Approve is exercised from the signed-out round trip in
// books/oauth-authorize.spec.ts; this covers Deny and the phone layout.
test.describe('OAuth authorize page, signed in as a member', () => {
  let client: OauthClient;
  let callback: Server;

  test.beforeAll(async ({ request }) => {
    client = await registerClient(request, 43102);
    callback = await startCallbackServer(43102);
  });

  test.afterAll(() => {
    callback.close();
  });

  test('shows what is asked and Deny sends access_denied to the client', async ({ page }) => {
    await page.goto(client.authorizeUrl);

    await expect(page.getByTestId('oauth-redirect-host')).toHaveText('127.0.0.1:43102');
    await expect(page.getByText(/Read books and authors/)).toBeVisible();

    await page.getByTestId('oauth-deny').click();

    await page.waitForURL(client.callbackPattern);
    const landed = new URL(page.url());
    expect(landed.searchParams.get('error')).toBe('access_denied');
    expect(landed.searchParams.get('state')).toBe(client.state);
    expect(landed.searchParams.get('code')).toBeNull();
  });

  test('fits a phone screen', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 800 });
    await page.goto(client.authorizeUrl);
    await expect(page.getByTestId('oauth-approve')).toBeVisible();
    await expect(page.getByTestId('oauth-deny')).toBeVisible();

    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
