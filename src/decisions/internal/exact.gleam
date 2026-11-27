//// Exact JSON values for the parts of a record that hold an output: a
//// json_blueprint `Value` keeps every number as written, where `gleam/json`
//// reads numbers as floats. The parts that hold no output are read with
//// their `gleam/json` decoders.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import json/blueprint/value.{type Value}

/// A `gleam/json` value as a `Value`. The text is the library's own, so it
/// parses without the limits for untrusted input, and it always parses.
pub fn from_json(item: Json) -> Value {
  let assert Ok(parsed) = value.parse(json.to_string(item), value.unlimited())
  parsed
}

/// An object whose `"t"` member names the variant, followed by `fields`.
pub fn tagged(tag: String, fields: List(#(String, Value))) -> Value {
  value.Object([#("t", value.String(tag)), ..fields])
}

/// The members of a JSON object.
pub fn members(raw: Value) -> Result(List(#(String, Value)), String) {
  case raw {
    value.Object(members) -> Ok(members)
    _ -> Error("expected an object")
  }
}

/// A member that holds no output, read with its `gleam/json` decoder.
pub fn member(
  members: List(#(String, Value)),
  name: String,
  decoder: Decoder(a),
) -> Result(a, String) {
  case list.key_find(members, name) {
    Ok(found) ->
      json.parse(value.to_string(found), decoder)
      |> result.replace_error("\"" <> name <> "\" does not decode")
    Error(Nil) -> Error("\"" <> name <> "\" is missing")
  }
}

/// A member that may be absent or null, read with its `gleam/json` decoder.
pub fn optional_member(
  members: List(#(String, Value)),
  name: String,
  decoder: Decoder(a),
) -> Result(Option(a), String) {
  case list.key_find(members, name) {
    Ok(_) -> member(members, name, decode.optional(decoder))
    Error(Nil) -> Ok(None)
  }
}

/// A member that holds a value with an output, read with `read`.
pub fn output_member(
  members: List(#(String, Value)),
  name: String,
  read: fn(Value) -> Result(a, String),
) -> Result(a, String) {
  case list.key_find(members, name) {
    Ok(found) -> read(found)
    Error(Nil) -> Error("\"" <> name <> "\" is missing")
  }
}
