import { expect, test, type Page } from "@playwright/test";
import { COMPUTER_PLANS, type CloudComputer } from "../shared/cloud";

const awaitingPayment = (): CloudComputer => ({
  id: "computer_browser_fixture",
  name: "My computer",
  plan: COMPUTER_PLANS[0],
  image: "ubuntu:24.04",
  state: "payment_pending",
  workspaceId: null,
  subscription: null,
  error: null,
  checkout: {
    id: "bco_fixture",
    url: "https://checkout.stripe.com/c/pay/fixture",
  },
  purchase: {
    status: "awaiting_payment",
    canContinue: true,
    canCancel: true,
    error: null,
  },
});
type Scenario = {
  computer: CloudComputer;
  requests: string[];
  checkoutResult?: CloudComputer;
  checkoutError?: {
    error: string;
    code: string;
    details: { retryable: boolean; reference: string };
  };
  cancelResult?: CloudComputer;
  reconcileResult?: CloudComputer;
};

async function openPurchase(page: Page, initial = awaitingPayment()) {
  const scenario: Scenario = { computer: initial, requests: [] };
  await page.clock.install();
  // Every account/provider request is local fixture data. These browser tests
  // never charge, cancel, or mutate a real account or provider reservation.
  await page.route("**/api/**", async (route) => {
    const request = route.request(),
      path = new URL(request.url()).pathname;
    scenario.requests.push(`${request.method()} ${path}`);
    const json = (body: unknown, status = 200) =>
      route.fulfill({ status, json: body });
    if (path === "/api/account/get-session")
      return json({
        user: { id: "fixture", email: "fixture@example.test", name: "Fixture" },
      });
    if (path === "/api/cloud/catalog")
      return json({ available: true, plans: COMPUTER_PLANS });
    if (path === "/api/cloud/computers")
      return json({
        computers:
          scenario.computer.state === "deleted" ? [] : [scenario.computer],
      });
    const prefix = `/api/cloud/computers/${initial.id}`;
    if (path === prefix) return json({ computer: scenario.computer });
    if (path === `${prefix}/checkout`) {
      if (scenario.checkoutError) {
        scenario.computer = {
          ...scenario.computer,
          state: "draft",
          checkout: null,
          error: scenario.checkoutError.error,
          purchase: {
            status: "draft",
            canContinue: true,
            canCancel: true,
            error: {
              code: scenario.checkoutError.code,
              ...scenario.checkoutError.details,
            },
          },
        };
        return json(scenario.checkoutError, 503);
      }
      scenario.computer = scenario.checkoutResult ?? scenario.computer;
      return json({ computer: scenario.computer });
    }
    if (path === `${prefix}/checkout/cancel`) {
      scenario.computer = scenario.cancelResult ?? {
        ...scenario.computer,
        state: "deleted",
        checkout: null,
        purchase: null,
      };
      return json({ computer: scenario.computer });
    }
    if (path === `${prefix}/reconcile`) {
      scenario.computer = scenario.reconcileResult ?? scenario.computer;
      return json({ computer: scenario.computer });
    }
    if (path.startsWith("/api/cloud/provider/workspace/"))
      return json({ workspace: { ready: true, status: "running" } });
    throw new Error(`Unexpected browser API call: ${request.method()} ${path}`);
  });
  await page.goto(`/computers/${initial.id}`);
  await expect(
    page.getByRole("heading", { name: initial.name, exact: true }),
  ).toBeVisible();
  return scenario;
}

test("unpaid checkout shows Cancel beside Continue and requires explicit confirmation", async ({
  page,
}) => {
  const scenario = await openPurchase(page);
  await expect(
    page.getByRole("button", { name: "Continue checkout", exact: true }),
  ).toBeVisible();
  const cancel = page.getByRole("button", {
    name: "Cancel purchase",
    exact: true,
  });
  await expect(cancel).toBeVisible();
  await cancel.click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("button", { name: "Keep purchase" }).click();
  expect(scenario.requests.some((r) => r.endsWith("/checkout/cancel"))).toBe(
    false,
  );
  await cancel.click();
  await dialog
    .getByRole("button", { name: "Cancel purchase", exact: true })
    .click();
  await expect(page).toHaveURL(/\/computers$/);
  expect(
    scenario.requests.filter((r) => r.endsWith("/checkout/cancel")),
  ).toHaveLength(1);
  await expect(
    page.getByRole("heading", {
      name: "Your next computer, ready when you are",
    }),
  ).toBeVisible();
});

test("unconfirmed checkout stops automatic recovery and Resume opens only the recovered payment", async ({
  page,
}) => {
  const initial = awaitingPayment();
  initial.state = "checkout_pending";
  initial.checkout = null;
  initial.purchase = {
    status: "recovering",
    canContinue: true,
    canCancel: false,
    error: null,
  };
  const scenario = await openPurchase(page, initial);
  await expect(
    page.getByRole("button", { name: "Cancel purchase", exact: true }),
  ).toBeDisabled();
  await page.clock.fastForward(60000);
  expect(
    scenario.requests.filter((r) => r.endsWith("/reconcile")),
  ).toHaveLength(0);
  scenario.checkoutResult = awaitingPayment();
  await page.route("https://checkout.stripe.com/**", (route) =>
    route.fulfill({ body: "Fixture checkout" }),
  );
  await page.getByRole("button", { name: "Resume checkout" }).click();
  await expect(page).toHaveURL("https://checkout.stripe.com/c/pay/fixture");
  expect(scenario.requests.filter((r) => r.endsWith("/checkout"))).toHaveLength(
    1,
  );
});

test("a rejected checkout explains the failure and stays cancelable without a polling loop", async ({
  page,
}) => {
  const initial = awaitingPayment();
  initial.state = "draft";
  initial.checkout = null;
  initial.purchase = {
    status: "draft",
    canContinue: true,
    canCancel: true,
    error: null,
  };
  const scenario = await openPurchase(page, initial);
  scenario.checkoutError = {
    code: "billing_redirect_not_allowed",
    error: "Cloud checkout return address needs attention.",
    details: { retryable: false, reference: "fixture-support-reference" },
  };
  await page
    .getByRole("button", { name: "Continue checkout", exact: true })
    .click();
  await expect(
    page.getByText("Support reference: fixture-support-reference"),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(1);
  await page.clock.fastForward(60000);
  expect(
    scenario.requests.filter((r) => r.endsWith("/reconcile")),
  ).toHaveLength(0);
  await page
    .getByRole("button", { name: "Cancel purchase", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Cancel purchase", exact: true })
    .click();
  await expect(page).toHaveURL(/\/computers$/);
});

test("a payment completing during cancellation stays on payment confirmation", async ({
  page,
}) => {
  const scenario = await openPurchase(page);
  scenario.cancelResult = {
    ...awaitingPayment(),
    checkout: null,
    purchase: {
      status: "processing",
      canContinue: false,
      canCancel: false,
      error: null,
    },
  };
  await page
    .getByRole("button", { name: "Cancel purchase", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Cancel purchase", exact: true })
    .click();
  await expect(page).toHaveURL(/\/computers\/computer_browser_fixture$/);
  await expect(
    page.getByRole("button", { name: "Check payment" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Continue checkout", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Cancel purchase", exact: true }),
  ).toHaveCount(0);
  scenario.reconcileResult = {
    ...awaitingPayment(),
    state: "ready",
    workspaceId: "vm_fixture",
    checkout: null,
    purchase: null,
  };
  await page.getByRole("button", { name: "Check payment" }).click();
  await expect(
    page.getByRole("button", { name: "Manage billing" }),
  ).toBeVisible();
});

test("expired payments stop polling and offer cancellation without opening checkout", async ({
  page,
}) => {
  const initial = awaitingPayment();
  initial.checkout = null;
  initial.purchase = {
    status: "expired",
    canContinue: false,
    canCancel: true,
    error: null,
  };
  const scenario = await openPurchase(page, initial);
  await expect(
    page.getByRole("button", { name: "Continue checkout", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Cancel purchase", exact: true }),
  ).toBeEnabled();
  await page.clock.fastForward(60000);
  expect(
    scenario.requests.filter((r) => r.endsWith("/reconcile")),
  ).toHaveLength(0);
});
