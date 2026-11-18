import { isAddress } from "viem";

export type ChainConfig = {
  label: string;
  agentRegistry: `0x${string}` | "";
  usdt: `0x${string}` | "";
  policyDesk: `0x${string}` | "";
  explorer: string;
};

export const OFFICIAL_REGISTRY = "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F" as const;
export const OFFICIAL_USDT = "0x55d398326f99059fF775485246999027B3197955" as const;
const STORAGE_KEY = "agent-policy-desk.overrides.v1";

const DEFAULTS: Record<string, ChainConfig> = {
  "56": {
    label: "BNB Smart Chain",
    agentRegistry: OFFICIAL_REGISTRY,
    usdt: OFFICIAL_USDT,
    policyDesk: "",
    explorer: "https://bscscan.com",
  },
  "31337": {
    label: "Local / Fork",
    agentRegistry: "",
    usdt: "",
    policyDesk: "",
    explorer: "",
  },
};

type OverrideRow = {
  agentRegistry: `0x${string}` | "";
  usdt: `0x${string}` | "";
  policyDesk: `0x${string}` | "";
};

function blank(id: string): ChainConfig {
  return {
    label: `Chain ${id}`,
    agentRegistry: "",
    usdt: "",
    policyDesk: "",
    explorer: "",
  };
}

function cleanAddress(value: unknown): `0x${string}` | "" {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  if (!trimmed) return "";
  return isAddress(trimmed) ? trimmed : "";
}

function readOverrides(): Record<string, OverrideRow> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as Record<string, Partial<OverrideRow>>;
    const clean: Record<string, OverrideRow> = {};
    for (const [id, row] of Object.entries(parsed)) {
      if (!/^\d+$/.test(id) || !row || typeof row !== "object") continue;
      clean[id] = {
        agentRegistry: cleanAddress(row.agentRegistry),
        usdt: cleanAddress(row.usdt),
        policyDesk: cleanAddress(row.policyDesk),
      };
    }
    return clean;
  } catch {
    return {};
  }
}

export async function loadConfigs(): Promise<Record<string, ChainConfig>> {
  const merged: Record<string, ChainConfig> = structuredClone(DEFAULTS);
  try {
    const response = await fetch("/config.json", { cache: "no-store" });
    if (response.ok) {
      const body = (await response.json()) as { chains?: Record<string, Record<string, unknown>> };
      for (const [id, row] of Object.entries(body.chains ?? {})) {
        if (!/^\d+$/.test(id) || !row) continue;
        const current = merged[id] ?? blank(id);
        const registry = cleanAddress(row.agentRegistry);
        const usdt = cleanAddress(row.usdt);
        const desk = cleanAddress(row.policyDesk);
        merged[id] = {
          label: typeof row.label === "string" && row.label.trim() ? row.label : current.label,
          agentRegistry: registry || current.agentRegistry,
          usdt: usdt || current.usdt,
          policyDesk: row.policyDesk === "" ? "" : desk || current.policyDesk,
          explorer: typeof row.explorer === "string" ? row.explorer : current.explorer,
        };
      }
    }
  } catch {
    // The built-in official addresses still work if the file cannot be fetched.
  }

  for (const [id, row] of Object.entries(readOverrides())) {
    const current = merged[id] ?? blank(id);
    merged[id] = {
      ...current,
      agentRegistry: row.agentRegistry,
      usdt: row.usdt,
      policyDesk: row.policyDesk,
    };
  }
  return merged;
}

export function saveOverride(chainId: number, value: OverrideRow): void {
  const all = readOverrides();
  all[String(chainId)] = {
    agentRegistry: cleanAddress(value.agentRegistry),
    usdt: cleanAddress(value.usdt),
    policyDesk: cleanAddress(value.policyDesk),
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(all));
}

export function clearOverride(chainId: number): void {
  const all = readOverrides();
  delete all[String(chainId)];
  localStorage.setItem(STORAGE_KEY, JSON.stringify(all));
}

export function hasOverride(chainId: number): boolean {
  return Object.prototype.hasOwnProperty.call(readOverrides(), String(chainId));
}
