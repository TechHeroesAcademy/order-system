/**
 * Canonical form used for storing/matching phone numbers everywhere a phone
 * number is a lookup key (staff login, driver-region lookups). Strips
 * everything but digits so "010 1234 5678", "010-1234-5678" and
 * "01012345678" all match the same account.
 */
export function normalizePhone(phone: string): string {
  return phone.replace(/\D/g, "");
}
