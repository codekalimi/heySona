export function summarizeForLog(value: unknown): string {
  try {
    const text = typeof value === "string" ? value : JSON.stringify(value);
    return text.length > 1200 ? `${text.slice(0, 1200)}…` : text;
  } catch {
    return String(value);
  }
}
