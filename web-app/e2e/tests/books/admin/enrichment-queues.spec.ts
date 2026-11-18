import { test, expect } from "@playwright/test";

test.describe("Books admin — enrichment queues", () => {
  test("lists the queues and copies the origin prompt", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/admin/enrichment_queues");
    await expect(page.getByRole("heading", { name: "Enrichment queues" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Book origin" })).toBeVisible();

    await page.getByTestId("copy-agent-prompt-origin").click();
    await expect(page.getByTestId("copy-agent-prompt-origin")).toHaveText("Copied!");
    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toContain("/api/mcp/admin");
    expect(text).toContain("claim_enrichment_items");
  });

  test("lists the book facts and author facts queues with their agent prompts", async ({ page }) => {
    await page.goto("/admin/enrichment_queues");
    for (const slug of ["book_facts", "author_facts"]) {
      const row = page.getByTestId(`queue-row-${slug}`);
      await expect(row).toBeVisible();
      await expect(row.getByTestId(`copy-agent-prompt-${slug}`)).toBeVisible();
      // The prompt is in a hidden textarea; read its value without pressing Copy or Fill.
      const prompt = await row.locator('textarea[data-clipboard-copy-target="source"]').inputValue();
      expect(prompt).toContain("claim_enrichment_items");
    }
  });

  test("opens a queue's items", async ({ page }) => {
    await page.goto("/admin/enrichment_queues");
    await page.getByRole("link", { name: "Book categories" }).click();
    await expect(page.getByRole("heading", { name: "Book categories" })).toBeVisible();
  });
});
