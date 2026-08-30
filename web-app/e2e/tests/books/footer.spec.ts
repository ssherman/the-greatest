import { test, expect } from '@playwright/test';

const CONTACT = 'contact@thegreatestbooks.org';

// The footer and both policy pages are shared across books, music and games --
// one FooterComponent and one PagesController, covered per-domain by
// test/components/footer_component_test.rb and
// test/controllers/pages_controller_test.rb. These run against books alone
// because it is the one e2e project here that needs no auth setup.
test.describe('Books footer', () => {
  test('links through to the privacy policy', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('link', { name: 'Privacy Policy' }).click();

    await expect(page).toHaveURL(/\/privacy_policy$/);
    await expect(page.getByRole('heading', { name: 'Privacy Policy', level: 1 })).toBeVisible();
  });

  test('links through to the deletion policy', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('link', { name: 'Deletion Policy' }).click();

    await expect(page).toHaveURL(/\/deletion_policy$/);
    await expect(page.getByRole('heading', { name: 'Deletion Policy', level: 1 })).toBeVisible();
  });

  test('the browse links point at real pages', async ({ page }) => {
    await page.goto('/');

    for (const name of ['Authors', 'Genres', 'Origins']) {
      const href = await page.locator('footer').getByRole('link', { name, exact: true }).getAttribute('href');
      const response = await page.request.get(href!);
      expect(response.status(), `${name} -> ${href}`).toBe(200);
    }
  });

  test('the contact control opens the form rather than a mail client', async ({ page }) => {
    await page.goto('/privacy_policy');

    const footer = page.locator('footer');

    await expect(footer.getByRole('button', { name: 'Contact', exact: true })).toBeVisible();
    await expect(footer.locator(`a[href="mailto:${CONTACT}"]`)).toHaveCount(0);
  });

  test('the policy body names the contact address', async ({ page }) => {
    await page.goto('/deletion_policy');

    const contact = page.locator('.prose').getByRole('link', { name: CONTACT });

    await expect(contact).toHaveAttribute('href', `mailto:${CONTACT}`);
  });
});
