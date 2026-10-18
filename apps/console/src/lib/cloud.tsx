import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { CloudComputer, ComputerPlan } from "@shared/cloud";
import { request } from "./api";

export interface CloudImage {
  id: string;
  label?: string;
  image: string;
  minimum_resources?: {
    cpus?: number;
    memory_mb?: number;
    disk_size_mb?: number;
  };
}
interface CloudCatalog {
  available: boolean;
  plans: ComputerPlan[];
}
const cloudRequest = <T,>(path: string, method = "GET", body?: unknown) =>
  request<T>(`/api/cloud${path}`, method, body);

function useCloudState() {
  const [computers, setComputers] = useState<CloudComputer[]>([]),
    [catalog, setCatalog] = useState<CloudCatalog>(),
    [images, setImages] = useState<CloudImage[]>([]);
  const [loaded, setLoaded] = useState(false),
    [error, setError] = useState("");
  const refreshing = useRef<Promise<void> | null>(null),
    reconciling = useRef(false);
  const reload = useCallback(() => {
    if (refreshing.current) return refreshing.current;
    const work = (async () => {
      try {
        const [inventory, pricing] = await Promise.all([
          cloudRequest<{ computers: CloudComputer[] }>("/computers"),
          cloudRequest<CloudCatalog>("/catalog"),
        ]);
        setComputers(inventory.computers);
        setCatalog(pricing);
        setLoaded(true);
        setError("");
      } catch (error) {
        setError((error as Error).message);
        throw error;
      } finally {
        refreshing.current = null;
      }
    })();
    refreshing.current = work;
    return work;
  }, []);
  useEffect(() => {
    void reload().catch(() => {});
  }, [reload]);
  useEffect(() => {
    if (
      !computers.some((c) =>
        [
          "checkout_pending",
          "payment_pending",
          "paid",
          "provisioning",
        ].includes(c.state),
      )
    )
      return;
    const timer = setInterval(async () => {
      if (reconciling.current || document.hidden) return;
      reconciling.current = true;
      try {
        let failure: string | undefined;
        for (const computer of computers.filter((c) =>
          [
            "checkout_pending",
            "payment_pending",
            "paid",
            "provisioning",
          ].includes(c.state),
        )) {
          try {
            await cloudRequest(`/computers/${computer.id}/reconcile`, "POST");
          } catch (error) {
            failure ??= (error as Error).message;
          }
        }
        await reload();
        if (failure) setError(failure);
      } catch (error) {
        setError((error as Error).message);
      } finally {
        reconciling.current = false;
      }
    }, 5000);
    return () => clearInterval(timer);
  }, [computers, reload]);
  const loadImages = useCallback(async () => {
    const result = await cloudRequest<{ images: CloudImage[] }>(
      "/provider/workspace/images?monthly=true",
    );
    setImages(result.images);
    return result.images;
  }, []);
  async function action(id: string, operation: string) {
    const result = await cloudRequest<{
      computer?: CloudComputer;
      url?: string;
    }>(`/computers/${encodeURIComponent(id)}/${operation}`, "POST");
    if (result.computer)
      setComputers((current) =>
        result.computer!.state === "deleted"
          ? current.filter((c) => c.id !== id)
          : current.map((c) => (c.id === id ? result.computer! : c)),
      );
    if (result.url) window.location.assign(result.url);
    else if (operation === "checkout" && result.computer?.checkout)
      window.location.assign(result.computer.checkout.url);
    await reload();
    return result;
  }
  async function purchase(
    name: string,
    imageId: string,
    planId: string,
    key: string,
  ) {
    const result = await cloudRequest<{ computer: CloudComputer }>(
      "/computers",
      "POST",
      { name, imageId, planId, idempotencyKey: key },
    );
    await reload();
    return action(result.computer.id, "checkout");
  }
  return {
    computers,
    catalog,
    images,
    loaded,
    error,
    reload,
    loadImages,
    action,
    purchase,
  };
}
const CloudContext = createContext<ReturnType<typeof useCloudState> | null>(
  null,
);
export function CloudProvider({ children }: { children: ReactNode }) {
  return (
    <CloudContext.Provider value={useCloudState()}>
      {children}
    </CloudContext.Provider>
  );
}
export function useCloud() {
  const value = useContext(CloudContext);
  if (!value) throw new Error("CloudProvider required");
  return value;
}
export const computerState = (computer: CloudComputer) =>
  ({
    draft: "Not purchased",
    checkout_pending: "Preparing checkout",
    payment_pending: "Awaiting payment",
    paid: "Payment confirmed",
    provisioning: "Setting up",
    ready: "Available",
    deleting: "Deleting",
    deleted: "Deleted",
  })[computer.state];
