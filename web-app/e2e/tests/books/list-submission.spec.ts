import { test, expect } from "@playwright/test";

test.describe("book list submission", () => {
  test("an anonymous visitor can submit a list", async ({ page }) => {
    await page.goto("/lists");
    await page.getByRole("link", { name: "Submit a list" }).click();

    await expect(page).toHaveURL(/\/lists\/new$/);

    const name = `E2E Test List ${Date.now()}`;
    await page.getByLabel("List name").fill(name);
    await page.getByLabel("Source or publication").fill("Playwright");
    await page.getByLabel("Link to the list").fill(`https://example.com/${Date.now()}`);

    await page.getByRole("button", { name: "Submit list" }).click();

    await expect(page).toHaveURL(/\/lists\/thanks$/);
    await expect(page.getByRole("heading", { name: /Thanks/ })).toBeVisible();
  });

  test("the optional detail section is collapsed by default", async ({ page }) => {
    await page.goto("/lists/new");

    // exact: true -- "Number of voters" is otherwise a substring match of the
    // "The number of voters is unknown" checkbox's label further down the same
    // panel, which trips Playwright's strict-mode "resolved to 2 elements".
    const numberOfVoters = page.getByLabel("Number of voters", {exact: true});
    await expect(numberOfVoters).toBeHidden();
    await page.getByText("More detail (optional)").click();
    await expect(numberOfVoters).toBeVisible();
  });
});
