import { test, expect } from '@playwright/test';

// Music has no MCP server yet, so nothing on it may point at one: the footer
// link stays plain "API" and /developers has no MCP pointer or section. The
// books side is in e2e/tests/books/developers.spec.ts.
test.describe('Music API docs, no MCP', () => {
  test('the footer says API and the docs page does not point at MCP', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('footer').getByRole('link', { name: 'API & MCP' })).toHaveCount(0);
    await page.locator('footer').getByRole('link', { name: 'API', exact: true }).click();

    await expect(page).toHaveURL(/\/developers$/);
    await expect(page.locator('#mcp-pointer')).toHaveCount(0);
    await expect(page.getByRole('heading', { level: 1, name: 'The Greatest Music API', exact: true })).toBeVisible();
    await expect(page.locator('#mcp')).toHaveCount(0);
  });
});
