// Must not compile: a model called directly, around `run`, so its reads
// would not be recorded.
import decisions_usage/same_context

pub fn bypass(context, sources) {
  let model = same_context.billing_model()
  model.call(context, sources)
}
