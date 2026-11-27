//// An output's JSON may nest deeper than json_blueprint's default parse
//// depth. A `plain` codec turned into a json_blueprint codec re-reads the
//// JSON its own encoder wrote, so that text is trusted and the default
//// bound for untrusted input must not refuse it.

import decisions/wire
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/result
import json/blueprint/codec as blueprint

/// An output that encodes as `depth` nested arrays.
pub type Nested {
  Nested(depth: Int)
}

fn encode(item: Nested) -> Json {
  nest(item.depth)
}

fn nest(depth: Int) -> Json {
  case depth {
    0 -> json.int(0)
    _ -> json.preprocessed_array([nest(depth - 1)])
  }
}

fn decoder() -> decode.Decoder(Nested) {
  decode.success(Nested(0))
}

pub fn a_plain_output_deeper_than_the_parse_default_encodes_test() {
  // json_blueprint's default parse limits refuse nesting beyond 128.
  let item = Nested(200)
  let codec = wire.blueprint(wire.plain(encode, decoder()))
  assert blueprint.to_json(codec, item) |> result.map(json.to_string)
    == Ok(json.to_string(encode(item)))
}
