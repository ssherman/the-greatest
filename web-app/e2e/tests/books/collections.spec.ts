import { test, expect } from '@playwright/test';

test.describe('Books curated collections', () => {
  test('the Lists menu links to a collection', async ({ page }) => {
    await page.goto('/');
    await page.setViewportSize({ width: 1280, height: 900 });

    await page.locator('.navbar-center summary', { hasText: 'Lists' }).click();
    await page.locator('.navbar-center a', { hasText: 'Greatest African Books' }).click();

    await expect(page).toHaveURL('/africa');
    await expect(page.getByRole('heading', { level: 1 }))
      .toHaveText('The Greatest African Books of All Time');
  });

  test('a collection page offers genre and year but not origin', async ({ page }) => {
    await page.goto('/africa');
    await page.getByRole('button', { name: 'Filters' }).click();
    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();

    await expect(page.locator("[data-level-target='category']")).toBeVisible();
    await expect(page.locator("[data-level-target='year']")).toBeVisible();
    await expect(page.locator("[data-level-target='country']")).toHaveCount(0);
  });

  test('applying a genre stays inside the collection', async ({ page }) => {
    await page.goto('/western');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator("[data-level-target='category']").click();

    const firstGenre = page
      .locator("turbo-frame#books_filter_pane_category label")
      .first();
    await firstGenre.waitFor();
    await firstGenre.click();

    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL(/\/western\/the-greatest\/[^/]+\/books$/);
  });

  // Guards a real bug: the submenu shipped at a fixed w-64 and the longer labels
  // ran outside the panel. Asserts no label wraps or overflows rather than a pixel
  // width, so relabelling a collection cannot silently break the menu again.
  test('every Lists menu label fits on one line', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/');
    await page.locator('.navbar-center summary', { hasText: 'Lists' }).click();

    const menu = page.locator('.navbar-center details ul');
    await expect(menu).toBeVisible();

    const report = await menu.evaluate((ul) => {
      const box = ul.getBoundingClientRect();
      let wrapped = 0;
      let overflowed = 0;
      const bad: string[] = [];
      ul.querySelectorAll('a').forEach((a) => {
        const r = a.getBoundingClientRect();
        const lineHeight = parseFloat(getComputedStyle(a).lineHeight) || 0;
        const isWrapped = lineHeight > 0 && r.height > lineHeight * 1.6;
        const isOverflow = r.right > box.right + 0.5 || a.scrollWidth > a.clientWidth + 1;
        if (isWrapped || isOverflow) bad.push((a.textContent || '').trim());
        if (isWrapped) wrapped++;
        if (isOverflow) overflowed++;
      });
      return { count: ul.querySelectorAll('a').length, wrapped, overflowed, bad };
    });

    expect(report.count).toBe(9);
    expect(report.bad, 'labels that wrap or overflow the panel').toEqual([]);
    expect(report.wrapped + report.overflowed).toBe(0);
  });
});
