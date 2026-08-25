import { test, expect } from '@playwright/test';

// The books Playwright project runs Desktop Chrome, which is above the `lg`
// breakpoint where the drawer is hidden. Every test here must set a phone
// viewport explicitly or it will assert against the desktop bar instead.
const PHONE = { width: 390, height: 844 };

test.describe('Books mobile nav drawer', () => {
  test.use({ viewport: PHONE });

  test('the hamburger opens the panel', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();

    await page.locator('#books-nav-drawer-button').click();

    await expect(page.locator('#books-nav-drawer-panel')).toBeVisible();
    await expect(page.locator('#books-nav-drawer-panel').getByRole('link', { name: 'Authors' })).toBeVisible();
  });

  test('Escape closes the panel', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await expect(page.locator('#books-nav-drawer-panel')).toBeVisible();

    await page.keyboard.press('Escape');

    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();
  });

  test('the hamburger reports its expanded state', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#books-nav-drawer-button')).toHaveAttribute('aria-expanded', 'false');

    await page.locator('#books-nav-drawer-button').click();

    await expect(page.locator('#books-nav-drawer-button')).toHaveAttribute('aria-expanded', 'true');
  });

  test('clicking a link navigates and leaves the drawer closed', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();

    await page.locator('#books-nav-drawer-panel').getByRole('link', { name: 'Authors' }).click();

    await expect(page).toHaveURL(/\/authors/);
    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();
  });

  // The regression test that matters. Turbo's page snapshot is cloneNode(true),
  // and the HTML spec propagates an input's *checkedness* into the clone. So
  // the outgoing page is cached with the toggle checked, and Back restores the
  // drawer open -- with the page behind it still scroll-locked by daisyUI's
  // :root:has(.drawer-toggle:checked) rule.
  test('going back does not restore an open drawer or a locked page', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await page.locator('#books-nav-drawer-panel').getByRole('link', { name: 'Authors' }).click();
    await expect(page).toHaveURL(/\/authors/);

    await page.goBack();

    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();
    await expect(page.locator('#books-nav-drawer')).not.toBeChecked();
    // Prove the page still scrolls -- the scroll lock is the harmful half.
    await expect
      .poll(async () => page.evaluate(() => getComputedStyle(document.documentElement).overflow))
      .not.toBe('hidden');
  });

  // Measured on the current markup: tabbing past the last panel link walks to
  // BODY, then the toggle, then a link in the navbar behind the overlay. The
  // controller sets `inert` on .drawer-content to stop that.
  test('background content is inert while the drawer is open', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('.drawer-content')).not.toHaveAttribute('inert', /.*/);

    await page.locator('#books-nav-drawer-button').click();
    await expect(page.locator('#books-nav-drawer-panel')).toBeVisible();

    await expect(page.locator('.drawer-content')).toHaveAttribute('inert', '');
  });

  // `display:none` does not clear `:checked`. Without the matchMedia uncheck,
  // widening past `lg` while open leaves the panel state stuck on.
  test('crossing the lg breakpoint while open resets the drawer', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await expect(page.locator('#books-nav-drawer')).toBeChecked();

    await page.setViewportSize({ width: 1280, height: 800 });

    await expect(page.locator('#books-nav-drawer')).not.toBeChecked();
    await expect(page.locator('.drawer-content')).not.toHaveAttribute('inert', /.*/);
  });

  test('the whole menu is reachable in landscape with Lists expanded', async ({ page }) => {
    await page.setViewportSize({ width: 844, height: 390 });
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await page.locator('#books-nav-drawer-panel').getByText('Lists', { exact: true }).click();

    const lastLink = page.locator('#books-nav-drawer-panel a').last();
    await lastLink.scrollIntoViewIfNeeded();

    await expect(lastLink).toBeInViewport();
  });
});

test.describe('Books header stays visible', () => {
  test('the header is still at the top of the viewport after scrolling', async ({ page }) => {
    await page.goto('/');

    const before = await page.locator('nav.navbar').boundingBox();
    expect(before?.y).toBe(0);

    await page.evaluate(() => window.scrollBy(0, 1500));

    const after = await page.locator('nav.navbar').boundingBox();
    expect(after?.y).toBe(0);
    await expect(page.locator('#navbar_login_button')).toBeInViewport();
  });

  test('the header stays visible on a phone too', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');

    await page.evaluate(() => window.scrollBy(0, 1500));

    const box = await page.locator('nav.navbar').boundingBox();
    expect(box?.y).toBe(0);
  });

  // The sidebar card on a book page is sticky in its own right. At the old
  // top-8 (32px) it sat 32px under the 64px header.
  test('the book detail sidebar card does not hide under the header', async ({ page }) => {
    await page.goto('/');
    const firstBook = page.locator('a[href^="/book/"]').first();
    await firstBook.click();
    await expect(page).toHaveURL(/\/book\//);

    await page.evaluate(() => window.scrollBy(0, 1200));

    const nav = await page.locator('nav.navbar').boundingBox();
    const card = await page.getByTestId('book-sidebar-card').boundingBox();
    expect(card!.y).toBeGreaterThanOrEqual(nav!.y + nav!.height);
  });
});
