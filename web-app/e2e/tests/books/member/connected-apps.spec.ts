import { test, expect } from '@playwright/test';
import { Server } from 'http';
import { OauthClient, registerClient, startCallbackServer } from '../../../helpers/oauth-client';

// Matched by `books-member`: a signed-in member. Approves a throwaway client,
// finds it under Connected apps on /developers/tokens, revokes it, and checks
// the unexchanged authorization code died with it.
test.describe('Connected apps on /developers/tokens', () => {
  const port = 43105;
  let clientName: string;
  let client: OauthClient;
  let callback: Server;

  test.beforeEach(async ({ page, request }) => {
    page.on('dialog', (dialog) => dialog.accept());
    // Unique per run, so a leftover row from a crashed run never matches.
    clientName = `E2E connected app ${Date.now()}`;
    client = await registerClient(request, port, { clientName });
    callback = await startCallbackServer(port);
  });

  test.afterEach(async ({ page }) => {
    callback.close();
    await page.goto('/developers/tokens');
    const row = page.locator('#developers_connections tr', { hasText: clientName });
    if ((await row.count()) > 0) {
      await row.getByRole('button', { name: `Revoke ${clientName}` }).click();
      await expect(row).toHaveCount(0);
    }
  });

  test('approve a client, see it under Connected apps, revoke it, and its code stops working', async ({
    page,
    request,
  }) => {
    await page.goto(client.authorizeUrl);
    await page.getByTestId('oauth-approve').click();
    await page.waitForURL(client.callbackPattern);
    const code = new URL(page.url()).searchParams.get('code')!;

    await page.goto('/developers/tokens');
    const row = page.locator('#developers_connections tr', { hasText: clientName });
    await expect(row).toContainText('127.0.0.1');
    await expect(row).toContainText('books:read');

    await row.getByRole('button', { name: `Revoke ${clientName}` }).click();
    await expect(page.locator('#developers_connections tr', { hasText: clientName })).toHaveCount(0);

    // Revoke ends the unexchanged code too (Connections.revoke! revokes grants).
    const token = await request.post('/api/oauth/token', {
      form: {
        grant_type: 'authorization_code',
        code,
        redirect_uri: client.redirectUri,
        client_id: client.clientId,
        code_verifier: client.verifier,
      },
    });
    expect(token.status()).toBe(400);
    expect((await token.json()).error).toBe('invalid_grant');
  });

  test('the Connected apps table fits a phone screen', async ({ page }) => {
    await page.goto(client.authorizeUrl);
    await page.getByTestId('oauth-approve').click();
    await page.waitForURL(client.callbackPattern);

    await page.setViewportSize({ width: 375, height: 800 });
    await page.goto('/developers/tokens');
    await expect(page.locator('#developers_connections tr', { hasText: clientName })).toBeVisible();

    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
    expect(scrollWidth).toBeLessThanOrEqual(375);
  });
});
