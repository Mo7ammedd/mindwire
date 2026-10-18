import type { Oblien } from "oblien";
import { COMPUTER_PLANS } from "../../shared/cloud";

type Image = Awaited<ReturnType<Oblien["workspaces"]["images"]["list"]>>["images"][number];

/** Only a priced image that fits a published computer can enter checkout. */
export function monthlyComputerImage(image: Image): boolean {
  if (!["linux", "macos"].includes(image.base_os?.family ?? "")) return false;
  return COMPUTER_PLANS.some(plan => plan.vcpus >= (image.minimum_resources?.cpus ?? 1) &&
    plan.memoryMb >= (image.minimum_resources?.memory_mb ?? 1024) && plan.diskGb * 1024 >= (image.minimum_resources?.disk_size_mb ?? 1024));
}
