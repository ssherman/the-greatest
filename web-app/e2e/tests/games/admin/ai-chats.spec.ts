import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin AI Chats', () => {
  test('sidebar reaches AI Chats and a chat opens', async ({ page, gamesDashboardPage }) => {
    await gamesDashboardPage.goto();
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
