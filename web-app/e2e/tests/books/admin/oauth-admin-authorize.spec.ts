import { test, expect } from '@playwright/test';
import { Server } from 'http';
import { OauthClient, registerClient, startCallbackServer } from '../../../helpers/oauth-client';

// Matched by the admin storage-state project: signed in as an admin.
test.describe('OAuth authorize page for admin access', () => {
  let client: OauthClient;
  let callback: Server;

  test.beforeAll(async ({ request }) => {
    client = await registerClient(request, 43104, {
      resource: 'https://dev-new.thegreatestbooks.org/api/mcp/admin',
      scope: 'books:admin:read books:admin:write books:admin:merge',
    });
    callback = await startCallbackServer(43104);
  });

  test.afterAll(() => {
    callback.close();
  });

  test('lists the merge scope and the 30-day notice, and Approve lands on the callback with a code', async ({ page }) => {
    await page.goto(client.authorizeUrl);

    await expect(page.getByText(/Merge books, authors and categories/)).toBeVisible();
    await expect(page.getByText('Admin access must be approved again after 30 days.')).toBeVisible();

    await page.getByTestId('oauth-approve').click();

    await page.waitForURL(client.callbackPattern);
    const landed = new URL(page.url());
    expect(landed.searchParams.get('code')).toBeTruthy();
    expect(landed.searchParams.get('state')).toBe(client.state);
  });
});
