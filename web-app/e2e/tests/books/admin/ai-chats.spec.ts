import { test, expect } from '@playwright/test';

test.describe('Books Admin AI Chats', () => {
  test('sidebar reaches AI Chats and a chat opens', async ({ page }) => {
    await page.goto('/admin');
    await page.getByTestId('admin-sidebar').getByRole('link', { name: 'AI Chats', exact: true }).click();

    await expect(page).toHaveURL(/\/admin\/ai_chats/);
    await expect(page.getByRole('heading', { name: 'AI Chats', exact: true })).toBeVisible();

    const view = page.getByTitle('View').first();
    if (await view.count() === 0) {
      await expect(page.getByText('No AI chats found')).toBeVisible();
      return;
    }
    await view.click();
    await expect(page).toHaveURL(/\/admin\/ai_chats\/\d+/);
    await expect(page.getByRole('heading', { name: /^AI Chat #\d+$/ })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Basic Information' })).toBeVisible();
  });
});
