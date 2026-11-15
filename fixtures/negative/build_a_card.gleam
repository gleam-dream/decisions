// Must not compile: a card built outside the library, to skip `open`.
import decisions
import decisions_usage/clinic

pub fn forge(occurrence) {
  decisions.Card(occurrence:, validator: clinic.bia, seen: 3)
}
