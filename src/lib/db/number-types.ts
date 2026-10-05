import { types as pgTypes } from "pg";

/**
 * Counts and averages arrive as JavaScript numbers, not strings.
 *
 * node-postgres returns bigint (int8) and numeric as STRINGS by default,
 * because either can hold a value no JS number can represent exactly. That
 * default is right for a general driver and wrong for this application:
 * PostgREST used to serialise both as JSON numbers, every DashboardStats /
 * report type in src/types/database.ts declares `number`, and the query
 * builder hands RPC rows through with an `as` cast — so TypeScript could not
 * see the change and nothing failed loudly.
 *
 * What it did instead was arithmetic on strings. The owner dashboard adds
 * three counts together for "مع المندوبين":
 *
 *   stats.assigned_orders + stats.collected_orders + stats.with_driver_orders
 *
 * With strings that concatenates — three zeroes rendered as "000", and
 * 1 + 0 + 2 rendered as "102". Every count in dashboard_stats, daily_report,
 * monthly_report, the five *_report functions, customer_order_history and
 * order_customer_context is a bigint, so this was the whole reporting layer.
 *
 * Safe here because every one of those values is a row count, an average
 * duration in hours, or a percentage. The largest is bounded by the number
 * of orders this business will ever take; none comes close to 2^53. Money is
 * not stored as numeric anywhere in this schema — if it ever is, that column
 * wants its own parser, not this one.
 *
 * Deliberately NOT inside pool.ts, and deliberately without "server-only":
 * the registration is global to the pg module, and keeping it in a plain
 * module is what lets a test import it and assert that it happened.
 */
export function registerNumericTypeParsers(): void {
  pgTypes.setTypeParser(pgTypes.builtins.INT8, (v) => (v === null ? null : Number(v)));
  pgTypes.setTypeParser(pgTypes.builtins.NUMERIC, (v) => (v === null ? null : Number(v)));
}

registerNumericTypeParsers();
