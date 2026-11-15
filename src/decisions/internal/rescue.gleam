//// Turns a raise into a value, for the conformance check of a savepoint
//// whose body raises. Not for application use.

/// Run `body`; a raise becomes `Error(reason)`.
@external(erlang, "decisions_rescue_ffi", "rescue")
@external(javascript, "../../decisions_rescue_ffi.mjs", "rescue")
pub fn rescue(body: fn() -> a) -> Result(a, String)
