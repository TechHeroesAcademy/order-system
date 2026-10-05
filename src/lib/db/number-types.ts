import { types as pgTypes } from "pg";

export function registerNumericTypeParsers(): void {
  pgTypes.setTypeParser(pgTypes.builtins.INT8, (v) => (v === null ? null : Number(v)));
  pgTypes.setTypeParser(pgTypes.builtins.NUMERIC, (v) => (v === null ? null : Number(v)));
}

registerNumericTypeParsers();
