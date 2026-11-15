//// A card as a typed document: the server encodes the view with the
//// card's codec, which carries a JSON Schema; a client that has the same
//// codec decodes it typed.

// snips-start: card-document
import decisions
import decisions/memory
import decisions/view.{type View}
import decisions_usage/clinic.{type Refund}
import decisions_usage/first_point
import gleam/result
import json/blueprint/codec

/// The schema a server publishes for its cards, as JSON text.
pub fn card_schema() -> Result(String, codec.SchemaError) {
  codec.schema_json(view.codec(clinic.refund_point() |> decisions.codec))
}

/// The server's side: the card as JSON text.
pub fn serve(card: decisions.Card(Refund)) -> Result(String, String) {
  view.of(card, content: fn(ref) { Ok("message " <> ref.id) })
  |> codec.encode_json(view.codec(decisions.codec(clinic.refund_point())), _)
  |> result.map_error(codec.describe_encode_error)
}

/// A client's side: the same document, decoded typed.
pub fn read(text: String) -> Result(View(Refund), String) {
  codec.decode_json(view.codec(decisions.codec(clinic.refund_point())), text)
  |> result.map_error(codec.describe_decode_error)
}

// snips-end: card-document

/// The whole topic: a card served and read back as the same view.
pub fn run() -> Bool {
  let store = memory.new()
  let assert Ok(waiting) = first_point.recommend(store)
  let assert Ok(card) =
    memory.transaction(
      store,
      decisions.open(
        first_point.desk(),
        _,
        occurrence: waiting.id,
        by: clinic.bia,
        latest: fn(ref) { ref.revision },
      ),
    )
  let assert Ok(text) = serve(card)
  let assert Ok(_) = card_schema()
  read(text) == Ok(view.of(card, content: fn(ref) { Ok("message " <> ref.id) }))
}
