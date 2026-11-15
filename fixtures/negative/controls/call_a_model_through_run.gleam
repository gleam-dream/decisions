// Control for call_a_model_without_run.
import decisions/model
import decisions_usage/same_context

pub fn through_run(context, sources) {
  model.run(same_context.billing_model(), context, sources)
}
