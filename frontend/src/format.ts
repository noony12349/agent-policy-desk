export function parseUnits(value: string, decimals: number): bigint {
  const trimmed = value.trim();
  if (!/^\d+(\.\d+)?$/.test(trimmed)) {
    throw new Error("金额格式不正确。请使用数字，例如 25 或 25.5。");
  }
  const [whole, frac = ""] = trimmed.split(".");
  if (frac.length > decimals) {
    throw new Error(`最多保留 ${decimals} 位小数。`);
  }
  const fracPart = frac.padEnd(decimals, "0");
  const base = 10n ** BigInt(decimals);
  const fracValue = fracPart.length === 0 ? 0n : BigInt(fracPart);
  return BigInt(whole) * base + fracValue;
}

export function formatUnits(value: bigint, decimals: number, maxFrac = 4): string {
  const negative = value < 0n;
  const magnitude = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = magnitude / base;
  const remainder = magnitude % base;
  let frac = decimals === 0 ? "" : remainder.toString().padStart(decimals, "0").slice(0, maxFrac).replace(/0+$/, "");
  if (magnitude > 0n && whole === 0n && frac === "" && maxFrac < decimals) {
    const tiny = `<0.${"0".repeat(Math.max(0, maxFrac - 1))}1`;
    return negative ? `-${tiny}` : tiny;
  }
  const body = frac ? `${whole.toString()}.${frac}` : whole.toString();
  return negative ? `-${body}` : body;
}

export function formatExact(value: bigint, decimals: number): string {
  return formatUnits(value, decimals, decimals);
}

export function formatGrouped(value: bigint, decimals: number, maxFrac = 4): string {
  const text = formatUnits(value, decimals, maxFrac);
  if (text.includes("<")) return text;
  const negative = text.startsWith("-");
  const raw = negative ? text.slice(1) : text;
  const [whole, frac] = raw.split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const body = frac ? `${grouped}.${frac}` : grouped;
  return negative ? `-${body}` : body;
}

export function shortAddress(address: string): string {
  if (address.length < 12) return address;
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function defaultExpiryInput(): string {
  const date = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
  const pad = (part: number) => String(part).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function expiryToUnix(value: string): bigint {
  const ms = new Date(value).getTime();
  if (Number.isNaN(ms)) throw new Error("到期时间无效。");
  const seconds = Math.floor(ms / 1000);
  if (seconds <= Math.floor(Date.now() / 1000)) throw new Error("到期时间必须晚于现在。");
  return BigInt(seconds);
}

export function formatTime(seconds: bigint): string {
  const value = Number(seconds);
  if (!Number.isFinite(value)) return "—";
  return new Date(value * 1000).toLocaleString("zh-CN", { hour12: false });
}

export function percent(used: bigint, limit: bigint): number {
  if (limit <= 0n) return 0;
  const scaled = Number((used * 10_000n) / limit) / 100;
  if (!Number.isFinite(scaled)) return used > 0n ? 100 : 0;
  return Math.max(0, Math.min(100, scaled));
}
