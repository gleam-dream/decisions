// Collects the reads a model received while `decisions/model.run` runs it.
// The cell is closed however the model ends, and a read pushed after that
// is ignored.
import { Ok, Error, toList } from "./gleam.mjs";

export function with_cell(body) {
  const cell = { open: true, reads: [] };
  try {
    const value = body(cell);
    return new Ok([value, toList(cell.reads)]);
  } catch (error) {
    const message =
      error && typeof error.message === "string"
        ? error.message
        : String(error);
    return new Error(message);
  } finally {
    cell.open = false;
  }
}

export function push(cell, ref) {
  if (cell.open) cell.reads.push(ref);
  return undefined;
}
