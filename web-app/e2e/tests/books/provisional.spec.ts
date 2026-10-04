import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Goodreads import spec §9: a provisional book or author loads by URL, shows a
// notice, and is noindex. The rake tasks run from web-app, like reject-link.spec.ts.
const WEB_APP = path.resolve(__dirname, "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });
const lastJson = (output: string) => {
  const lines = output.trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
};

let seed: { book_slug: string; author_slug: string };

test.describe("Books — provisional records", () => {
  test.beforeAll(() => {
    seed = lastJson(rails("e2e:provisional_seed"));
  });

  test.afterAll(() => {
    rails("e2e:provisional_cleanup");
  });

  test("a provisional book shows the notice and is noindex", async ({ page }) => {
    await page.goto(`/book/${seed.book_slug}`);

    await expect(page.getByTestId("provisional-notice")).toBeVisible();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
  });

  test("a provisional author shows the notice and is noindex", async ({ page }) => {
    await page.goto(`/author/${seed.author_slug}`);

    await expect(page.getByTestId("provisional-notice")).toBeVisible();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
  });

  test("a catalog book shows no notice", async ({ page }) => {
    await page.goto("/book/headlong-hall");

    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page.getByTestId("provisional-notice")).toHaveCount(0);
  });
});
