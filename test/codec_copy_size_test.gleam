//// What a codec costs when it is copied to another process. A point holds
//// its output codec, and an application keeps points in desks that travel
//// with job closures and actor state, so the codec is copied on every
//// send. A copy does not keep sharing: a value captured by several
//// closures is copied once per closure. The bytes measured here are the
//// flat size of each term, as a send copies it.

import decisions.{Gated}
import decisions/memory
import decisions/view
import decisions/wire
import gleam/option.{type Option}
import json/blueprint/codec as blueprint

@external(erlang, "decisions_test_ffi", "copied_bytes")
fn copied_bytes(term: a) -> Int

pub type Line {
  Line(sku: String, quantity: Int, note: Option(String))
}

pub type Party {
  Party(name: String, email: String, tags: List(String))
}

pub type Order {
  Order(fee: String, cents: Int, party: Party, lines: List(Line))
}

/// A nested output: a record holding a record and a list of records.
fn order() -> blueprint.Codec(Order) {
  use fee <- blueprint.field("fee", blueprint.string(), get: fn(o: Order) {
    o.fee
  })
  use cents <- blueprint.field("cents", blueprint.int(), get: fn(o: Order) {
    o.cents
  })
  use party <- blueprint.field("party", party(), get: fn(o: Order) { o.party })
  use lines <- blueprint.field(
    "lines",
    blueprint.list(line()),
    get: fn(o: Order) { o.lines },
  )
  blueprint.success(Order(fee:, cents:, party:, lines:))
}

fn party() -> blueprint.Codec(Party) {
  use name <- blueprint.field("name", blueprint.string(), get: fn(p: Party) {
    p.name
  })
  use email <- blueprint.field("email", blueprint.string(), get: fn(p: Party) {
    p.email
  })
  use tags <- blueprint.field(
    "tags",
    blueprint.list(blueprint.string()),
    get: fn(p: Party) { p.tags },
  )
  blueprint.success(Party(name:, email:, tags:))
}

fn line() -> blueprint.Codec(Line) {
  use sku <- blueprint.field("sku", blueprint.string(), get: fn(l: Line) {
    l.sku
  })
  use quantity <- blueprint.field("quantity", blueprint.int(), get: fn(l: Line) {
    l.quantity
  })
  use note <- blueprint.field(
    "note",
    blueprint.nullable(blueprint.string()),
    get: fn(l: Line) { l.note },
  )
  blueprint.success(Line(sku:, quantity:, note:))
}

/// A point's codec holds the json_blueprint codec it was built from and
/// little else: no rendered schema, no closure over the codec beside it.
pub fn a_point_codec_costs_about_its_blueprint_test() {
  let bare = copied_bytes(order())
  let held = copied_bytes(wire.codec(order()))
  assert held <= bare + 64
}

/// The term that travels: a desk's waker, which a Grind job's closure or a
/// runtime process's state holds. It carries the point's codec once.
pub fn a_waker_carries_its_point_codec_once_test() {
  let desk =
    decisions.desk(
      decisions.point("orders.order", wire.codec(order())),
      drives: fn(_) {
        Gated(name: "ship", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) {
          Ok(Nil)
        })
      },
      under: fn(_) { Error("no policy") },
      over: memory.port(),
    )
  assert copied_bytes(decisions.waker(desk)) <= copied_bytes(order()) + 1024
}

/// The card codec over a nested output stays small: neither the output
/// codec nor its schema is captured by every field of the document.
pub fn the_card_codec_does_not_multiply_its_output_codec_test() {
  assert copied_bytes(view.codec(wire.codec(order()))) < 24_000
}
