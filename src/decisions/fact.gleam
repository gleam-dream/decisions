//// Typed fact keys. A fact's name and type are declared once, as a key.
////
//// A point declares the facts a policy may read with the key
//// (`decisions.fact` and `decisions.signal`), a policy written in Gleam
//// builds its conditions with the same key (`decisions/policy.below` and
//// the others), and a model reports its signals with `set`. A misspelt
//// name, or a number rule on a text fact, then does not compile. A policy
//// that arrives as stored data is checked against the point's declared
//// keys by `decisions.publishable`.
////
//// ```gleam
//// import decisions/fact
////
//// pub fn amount() -> fact.Key(Float) {
////   fact.number("amount")
//// }
////
//// let signals = [fact.set(amount(), 80.0)]
//// ```
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/vocabulary.{type Fact, type Facts, Flag, Number, Text}
import gleam/list

/// A named fact of type `a`. Build one with `number`, `text` or `flag`.
pub opaque type Key(a) {
  Key(
    name: String,
    kind: Kind,
    wrap: fn(a) -> Fact,
    unwrap: fn(Fact) -> Result(a, Nil),
  )
}

/// The type of a fact, as a stored policy and the publish check see it.
pub type Kind {
  NumberFact
  TextFact
  FlagFact
}

/// A key for a number, such as an amount or a score.
pub fn number(name: String) -> Key(Float) {
  Key(name:, kind: NumberFact, wrap: Number, unwrap: fn(fact) {
    case fact {
      Number(value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// A key for a text, such as an environment or a category.
pub fn text(name: String) -> Key(String) {
  Key(name:, kind: TextFact, wrap: Text, unwrap: fn(fact) {
    case fact {
      Text(value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// A key for a yes or no.
pub fn flag(name: String) -> Key(Bool) {
  Key(name:, kind: FlagFact, wrap: Flag, unwrap: fn(fact) {
    case fact {
      Flag(value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// The fact the library supplies to every policy: whole minutes since the
/// recommendation. A rule that reads it makes a policy change its answer as
/// an occurrence waits, which is how escalation and "proceed if nobody
/// objects within the hour" are written. A point never declares it.
pub fn waited_minutes() -> Key(Float) {
  number("waited_minutes")
}

/// The key's name.
pub fn name(key: Key(a)) -> String {
  key.name
}

/// The key's type.
pub fn kind(key: Key(a)) -> Kind {
  key.kind
}

/// The type of a fact value.
pub fn kind_of(fact: Fact) -> Kind {
  case fact {
    Number(_) -> NumberFact
    Text(_) -> TextFact
    Flag(_) -> FlagFact
  }
}

/// One named fact, for a model's signals or a consulted point's answer.
pub fn set(key: Key(a), value: a) -> #(String, Fact) {
  #(key.name, key.wrap(value))
}

/// The fact value as stored, for building a condition over it.
pub fn wrap(key: Key(a), value: a) -> Fact {
  key.wrap(value)
}

/// The value of this key among `facts`. `Error(Nil)` when it is absent or
/// has another type.
pub fn get(facts: Facts, key: Key(a)) -> Result(a, Nil) {
  case list.key_find(facts, key.name) {
    Ok(found) -> key.unwrap(found)
    Error(Nil) -> Error(Nil)
  }
}
