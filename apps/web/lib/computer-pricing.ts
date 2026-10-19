import { cloudDashboardUrl } from "./product";
// Pure retail data, shared with Console checkout. Never duplicate amounts in the website.
import { COMPUTER_CATALOG_VERSION, COMPUTER_PLANS } from "../../console/shared/cloud";

export interface ComputerPricingPlan {
  id: string;
  name: string;
  monthlyCents: number;
  vcpus: number;
  memoryMb: number;
  diskGb: number;
}
export interface ComputerPricing { version: string; available: boolean; plans: ComputerPricingPlan[]; source?: "live" | "catalog" }

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
export function parseComputerPricing(value: unknown): ComputerPricing | null {
  if (!record(value) || value.currency !== "usd" || value.interval !== "monthly" || typeof value.version !== "string" ||
      typeof value.available !== "boolean" || !Array.isArray(value.plans) || !value.plans.length || value.plans.length > 20) return null;
  const ids = new Set<string>();
  const plans: ComputerPricingPlan[] = [];
  for (const item of value.plans) {
    if (!record(item) || typeof item.id !== "string" || !/^[a-z0-9-]{1,64}$/.test(item.id) || ids.has(item.id) || typeof item.name !== "string" || !item.name ||
        !["monthlyCents", "vcpus", "memoryMb", "diskGb"].every(key => typeof item[key] === "number" && Number.isSafeInteger(item[key]) && item[key] > 0)) return null;
    ids.add(item.id);
    plans.push(item as unknown as ComputerPricingPlan);
  }
  return { version: value.version, available: value.available, plans };
}

/** The same Mindwire catalog powers checkout, Console, the native app and this page. */
export async function getComputerPricing(): Promise<ComputerPricing> {
  const published: ComputerPricing = { version: COMPUTER_CATALOG_VERSION, plans: COMPUTER_PLANS.map(plan => ({ ...plan })), available: false, source: "catalog" };
  try {
    const response = await fetch(new URL("/api/cloud/catalog", cloudDashboardUrl), {
      next: { revalidate: 60 }, redirect: "error", signal: AbortSignal.timeout(5000),
    });
    const live = response.ok ? parseComputerPricing(await response.json()) : null;
    return live ? { ...live, source: "live" } : published;
  } catch { return published; }
}

export const usd = (cents: number) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: cents % 100 === 0 ? 0 : 2, maximumFractionDigits: 2 }).format(cents / 100);
