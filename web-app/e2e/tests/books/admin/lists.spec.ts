import { test, expect } from "@playwright/test";

test.describe("Books admin — lists", () => {
  test("lists index and links to New List", async ({ page }) => {
    await page.goto("/admin/lists");
    await expect(page.getByRole("heading", { name: "Book Lists", level: 1 })).toBeVisible();
  });

  test("creates a list and shows it without a wizard button", async ({ page }) => {
    const name = `E2E List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "Launch Wizard" })).toHaveCount(0);
  });

  test("edits a list name", async ({ page }) => {
    const name = `E2E Edit List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated List ${Date.now()}`;
    await page.locator('input[name="books_list[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Book List" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes a list", async ({ page }) => {
    const name = `E2E Delete List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/lists$/);
  });

  test("attaches and detaches a penalty via the modal", async ({ page }) => {
    const name = `E2E Penalty List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("button", { name: "+ Attach Penalty" }).click();
    const modal = page.locator("#attach_penalty_modal_dialog");
    await expect(modal).toBeVisible();
    const select = modal.locator('select[name="list_penalty[penalty_id]"]');
    const firstText = await select.locator('option:not([value=""])').first().innerText();
    await select.selectOption({ index: 1 });
    await modal.getByRole("button", { name: "Attach Penalty" }).click();

    const frame = page.locator("turbo-frame#list_penalties_list");
    await expect(frame.getByText(firstText)).toBeVisible({ timeout: 10000 });

    page.on("dialog", (d) => d.accept());
    await frame.getByRole("button", { name: "Delete" }).click();
    await expect(frame.getByText("No penalties attached to this list yet.")).toBeVisible({ timeout: 10000 });
  });
});
