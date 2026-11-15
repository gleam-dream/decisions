// Runs a function and turns a throw into Error(reason), for the
// conformance check of a savepoint whose body raises.
import { Ok, Error } from "./gleam.mjs";

export function rescue(body) {
  try {
    return new Ok(body());
  } catch (error) {
    return new Error(String(error && error.message ? error.message : error));
  }
}
