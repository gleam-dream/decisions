// A mutable table of text for `decisions/memory`. Every value is a string,
// so only what a database would hold survives `restart`.
import { Ok, Error, toList } from "./gleam.mjs";

export function new_() {
  return { rows: new Map() };
}

export function get(table, key) {
  return table.rows.has(key)
    ? new Ok(table.rows.get(key))
    : new Error(undefined);
}

export function put(table, key, value) {
  table.rows.set(key, value);
  return undefined;
}

export function rows(table) {
  return toList([...table.rows.entries()]);
}

export function restore(table, rows) {
  table.rows = new Map(rows.toArray());
  return undefined;
}

// Run body; when it returns an Error or throws, put every row back.
export function guarded(table, body) {
  const before = new Map(table.rows);
  try {
    const result = body();
    if (result instanceof Error) table.rows = before;
    return result;
  } catch (error) {
    table.rows = before;
    throw error;
  }
}
