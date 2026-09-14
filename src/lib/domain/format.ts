import { format, formatDistanceToNow } from "date-fns";
import { arEG } from "date-fns/locale";

export function formatDateTime(value: string | null | undefined): string {
  if (!value) return "—";
  return format(new Date(value), "d MMM yyyy، h:mm a", { locale: arEG });
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return "—";
  return format(new Date(value), "d MMM yyyy", { locale: arEG });
}

export function formatRelative(value: string | null | undefined): string {
  if (!value) return "—";
  return formatDistanceToNow(new Date(value), { addSuffix: true, locale: arEG });
}

const arabicDigits = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"];

/** Kept for optional use — Arabic-Indic digits. Most Egyptian business UIs
 * actually prefer Western digits, so callers opt in explicitly. */
export function toArabicDigits(input: string | number): string {
  return String(input).replace(/[0-9]/g, (d) => arabicDigits[Number(d)]);
}

export function formatHours(hours: number | null | undefined): string {
  if (hours === null || hours === undefined) return "—";
  if (hours < 1) return `${Math.round(hours * 60)} دقيقة`;
  if (hours < 48) return `${hours.toFixed(1)} ساعة`;
  return `${(hours / 24).toFixed(1)} يوم`;
}

export function formatPercent(value: number | null | undefined): string {
  if (value === null || value === undefined) return "—";
  return `${value.toFixed(1)}%`;
}
