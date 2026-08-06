import { expect, test } from "@playwright/test";

const commitSha = "abcdef1234567890abcdef1234567890abcdef12";
const parentSha = "1111111111111111111111111111111111111111";
const commitUrl = `https://github.com/example/project/commit/${commitSha}`;

const oldSource = [
  "///|",
  "pub fn format_change(input : String) -> String {",
  `  let label = "${"old-value-".repeat(48)}"`,
  "  label + input",
  "}",
].join("\n");

const newSource = [
  "///|",
  "pub fn format_change(input : String) -> String {",
  `  let label = "${"new-value-".repeat(48)}"`,
  "  label + input.trim()",
  "}",
].join("\n");

const apiCommit = {
  sha: commitSha,
  html_url: commitUrl,
  commit: { message: "Make the playground diff easier to scan" },
  parents: [{ sha: parentSha }],
  stats: { additions: 2, deletions: 2, total: 4 },
  files: [
    {
      filename: "src/format_change.mbt",
      status: "modified",
      additions: 2,
      deletions: 2,
      changes: 4,
    },
  ],
};

async function loadMockedCommit(page) {
  await page.route("https://**", route => route.abort("blockedbyclient"));
  await page.route("https://api.github.com/**", async route => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: JSON.stringify(apiCommit),
    });
  });
  await page.route("https://raw.githubusercontent.com/**", async route => {
    const revision = new URL(route.request().url()).pathname.split("/")[3];
    await route.fulfill({
      status: 200,
      contentType: "text/plain",
      headers: { "access-control-allow-origin": "*" },
      body: revision === parentSha ? oldSource : newSource,
    });
  });

  await page.goto("/");
  await page.getByLabel("GitHub commit URL").fill(commitUrl);
  await page.getByRole("button", { name: "Load diff" }).click();
  await expect(page.locator("table.split")).toBeVisible();
}

test("desktop keeps split columns balanced and switches views", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await loadMockedCommit(page);

  await expect(page.getByText("example/project@", { exact: false })).toBeVisible();

  const heroLayout = await page.locator(".hero").evaluate(hero => {
    const copy = hero.querySelector(".hero-copy").getBoundingClientRect();
    const controls = hero.querySelector(".hero-controls").getBoundingClientRect();
    return {
      copyX: copy.x,
      copyCenterY: copy.y + copy.height / 2,
      controlsX: controls.x,
      controlsCenterY: controls.y + controls.height / 2,
    };
  });
  expect(heroLayout.controlsX).toBeGreaterThan(heroLayout.copyX);
  expect(Math.abs(heroLayout.controlsCenterY - heroLayout.copyCenterY)).toBeLessThan(1);

  const maximumGutterWidth = await page
    .locator("table.split td.line-number")
    .evaluateAll(cells => Math.max(...cells.map(cell => cell.getBoundingClientRect().width)));
  expect(maximumGutterWidth).toBeLessThanOrEqual(64);

  const splitMetrics = await page.locator("table.split").evaluate(table => {
    const row = [...table.rows].find(candidate => candidate.querySelectorAll("td.ctx").length === 2);
    const codeCells = [...row.querySelectorAll("td.ctx")];
    return {
      tableWidth: table.getBoundingClientRect().width,
      leftWidth: codeCells[0].getBoundingClientRect().width,
      rightWidth: codeCells[1].getBoundingClientRect().width,
    };
  });
  expect(Math.abs(splitMetrics.leftWidth - splitMetrics.rightWidth)).toBeLessThanOrEqual(1);
  expect(splitMetrics.leftWidth).toBeGreaterThanOrEqual(splitMetrics.tableWidth * 0.4);
  expect(splitMetrics.rightWidth).toBeGreaterThanOrEqual(splitMetrics.tableWidth * 0.4);

  await page.getByRole("button", { name: "Use unified view" }).click();
  await expect(page.locator("table.unified")).toBeVisible();
  await expect(page.locator("table.split")).toHaveCount(0);
  await page.getByRole("button", { name: "Use split view" }).click();
  await expect(page.locator("table.split")).toBeVisible();
});

test("narrow viewport scrolls only the diff and keeps controls usable", async ({ page }) => {
  await page.setViewportSize({ width: 640, height: 900 });
  await loadMockedCommit(page);

  const heroLayout = await page.locator(".hero").evaluate(hero => {
    const copy = hero.querySelector(".hero-copy").getBoundingClientRect();
    const controls = hero.querySelector(".hero-controls").getBoundingClientRect();
    return { copyBottom: copy.bottom, controlsTop: controls.top };
  });
  expect(heroLayout.controlsTop).toBeGreaterThanOrEqual(heroLayout.copyBottom);

  const formFitsViewport = await page.locator(".commit-form").evaluate(form => {
    const input = form.querySelector("input").getBoundingClientRect();
    const button = form.querySelector("button").getBoundingClientRect();
    return input.left >= 0 && input.right <= innerWidth && button.left >= 0 && button.right <= innerWidth;
  });
  expect(formFitsViewport).toBe(true);

  const splitOverflow = await page.locator(".diff-scroll").evaluate(scroller => {
    const codeCells = [...scroller.querySelectorAll("table.split td.ctx, table.split td.del, table.split td.add")];
    return {
      clientWidth: scroller.clientWidth,
      scrollWidth: scroller.scrollWidth,
      codeDoesNotWrap: codeCells.every(cell => getComputedStyle(cell).whiteSpace === "pre"),
      documentClientWidth: document.documentElement.clientWidth,
      documentScrollWidth: document.documentElement.scrollWidth,
    };
  });
  expect(splitOverflow.scrollWidth).toBeGreaterThan(splitOverflow.clientWidth);
  expect(splitOverflow.codeDoesNotWrap).toBe(true);
  expect(splitOverflow.documentScrollWidth).toBeLessThanOrEqual(splitOverflow.documentClientWidth);

  const scroller = page.locator(".diff-scroll");
  await scroller.evaluate(element => {
    element.scrollLeft = 120;
  });
  expect(await scroller.evaluate(element => element.scrollLeft)).toBeGreaterThan(0);

  const fileButton = page.locator(".file-card button");
  await fileButton.click();
  await expect(page.locator(".file-card .diff-scroll")).toHaveCount(0);
  await expect(fileButton).toHaveText("Expand");
  await fileButton.click();
  await expect(page.locator(".file-card .diff-scroll")).toBeVisible();

  await page.getByRole("button", { name: "Use unified view" }).click();
  await expect(page.locator("table.unified")).toBeVisible();
  const unifiedOverflow = await page.locator(".diff-scroll").evaluate(element => ({
    clientWidth: element.clientWidth,
    scrollWidth: element.scrollWidth,
  }));
  expect(unifiedOverflow.scrollWidth).toBeGreaterThan(unifiedOverflow.clientWidth);
});
