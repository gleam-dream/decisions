// Must not compile: a desk built outside the library, with a policy
// function that skips the publish check.
import decisions
import decisions/memory
import decisions_usage/clinic

pub fn forge() {
  decisions.Desk(
    point: clinic.refund_point(),
    tool: fn(_) { clinic.refund_fee() },
    policy: fn(_) { todo },
    port: memory.port(),
    consult: fn(_, _) { Ok(Nil) },
  )
}
