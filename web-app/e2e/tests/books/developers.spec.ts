import { test, expect } from '@playwright/test';

// Signed-out coverage of the public API pages. Matched by the `books` project
// (no storageState). Signed-in non-member coverage is in
// books/account/developers.spec.ts; the member flow is in
// books/member/developers-tokens.spec.ts.
test.describe('Books API developer pages, signed out', () => {
  test('the documentation page renders and lists the books endpoints', async ({ page }) => {
    await page.goto('/developers');

    await expect(page.getByRole('heading', { level: 1, name: /API/ })).toBeVisible();
    await expect(page.locator('#endpoint-listBooks')).toBeVisible();
    await expect(page.locator('#endpoint-listAuthors')).toBeVisible();
    await expect(page.locator('#errors-rate_limited')).toBeVisible();
  });

  test('the contract link serves the OpenAPI document for this host', async ({ page }) => {
    await page.goto('/developers');

    const href = await page.locator('article#developers').getByRole('link', { name: '/api/v1/openapi.json' }).getAttribute('href');
    const response = await page.request.get(href!);

    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(Object.keys(body.paths)).toContain('/api/v1/books');
    expect(body.servers[0].url).toBe('https://dev-new.thegreatestbooks.org');
  });

  test('the footer links to the documentation', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('link', { name: 'API', exact: true }).click();

    await expect(page).toHaveURL(/\/developers$/);
    await expect(page.getByRole('heading', { level: 1, name: /API/ })).toBeVisible();
  });

  test('the token page sends a signed-out visitor to the membership page', async ({ page }) => {
    await page.goto('/developers/tokens');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/Sign in to your membership/i)).toBeVisible();
  });

  test('the API itself refuses a request without a token', async ({ page }) => {
    const response = await page.request.get('/api/v1/books?per_page=1');

    expect(response.status()).toBe(401);
    expect(response.headers()['www-authenticate']).toBe('Bearer');
  });

  test('the documentation page explains how to connect an MCP client', async ({ page }) => {
    await page.goto('/developers');

    await expect(page.getByRole('heading', { level: 2, name: /MCP/ })).toBeVisible();
    await expect(page.locator('#mcp-command')).toContainText(
      'claude mcp add --transport http --scope user the-greatest-books https://dev-new.thegreatestbooks.org/api/mcp'
    );
    await expect(page.locator('#mcp-tool-find_book')).toBeVisible();
    await expect(page.locator('#mcp-tool-search_books')).toBeVisible();
  });

  test('the MCP endpoint refuses a request without a token', async ({ page }) => {
    const response = await page.request.post('/api/mcp', {
      data: { jsonrpc: '2.0', id: 1, method: 'tools/list' },
      headers: { Accept: 'application/json, text/event-stream' },
    });

    expect(response.status()).toBe(401);
    expect(response.headers()['www-authenticate']).toBe('Bearer');
  });
});
