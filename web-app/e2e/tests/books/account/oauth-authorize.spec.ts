import { test, expect } from '@playwright/test';
import { Server } from 'http';
import { OauthClient, registerClient, startCallbackServer } from '../../../helpers/oauth-client';

// Matched by `books-account`: PLAYWRIGHT_USER_EMAIL, signed in, NOT a member.
// Do not comp this account.
test.describe('OAuth authorize page, signed in as a non-member', () => {
  let client: OauthClient;
  let callback: Server;

  test.beforeAll(async ({ request }) => {
    client = await registerClient(request, 43103);
    callback = await startCallbackServer(43103);
  });

  test.afterAll(() => {
    callback.close();
  });

  test('explains membership and Return sends access_denied to the client', async ({ page }) => {
    await page.goto(client.authorizeUrl);

    await expect(page.getByRole('heading', { level: 1, name: 'Membership needed' })).toBeVisible();
    await expect(page.getByTestId('oauth-approve')).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'See membership' })).toHaveAttribute('href', '/membership');

    await page.getByRole('button', { name: 'Return to the app' }).click();

    await page.waitForURL(client.callbackPattern);
    const landed = new URL(page.url());
    expect(landed.searchParams.get('error')).toBe('access_denied');
    expect(landed.searchParams.get('state')).toBe(client.state);
  });

  test('asking for the admin resource says admin access is needed, with no membership link', async ({ page, request }) => {
    const adminClient = await registerClient(request, 43103, {
      resource: 'https://dev-new.thegreatestbooks.org/api/mcp/admin',
      scope: 'books:admin:read',
    });
    await page.goto(adminClient.authorizeUrl);

    await expect(page.getByRole('heading', { level: 1, name: 'Admin access needed' })).toBeVisible();
    await expect(page.getByTestId('oauth-approve')).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'See membership' })).toHaveCount(0);
  });
});
