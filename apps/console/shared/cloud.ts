/** Mindwire's retail catalog. Provider prices and credits never become account plans. */
export const COMPUTER_CATALOG_VERSION = "computers-monthly-v1";
export const COMPUTER_PLANS = [
  { id: "essential", name: "Essential", monthlyCents: 2400, vcpus: 2, memoryMb: 4096, diskGb: 60 },
  { id: "pro", name: "Pro", monthlyCents: 4900, vcpus: 4, memoryMb: 8192, diskGb: 120 },
  { id: "max", name: "Max", monthlyCents: 9900, vcpus: 8, memoryMb: 24576, diskGb: 240 },
] as const;
export type ComputerPlan = (typeof COMPUTER_PLANS)[number];
export type ComputerState = "draft" | "checkout_pending" | "payment_pending" | "paid" | "provisioning" | "ready" | "deleting" | "deleted";
export interface CloudComputer {
  id: string;
  name: string;
  plan: ComputerPlan;
  image: string;
  state: ComputerState;
  workspaceId: string | null;
  checkout: { url: string; id: string } | null;
  subscription: { status: string; paidThrough: string | null; cancelAtPeriodEnd: boolean } | null;
  error: string | null;
}
