///|
#export_name("evaluate_lifecycle")
pub fn evaluate_lifecycle(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activator = builder.activator()
  let (_, _stream) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  let held : Ref[@differential.Capability[Int64, Int64]?] = Ref(None)
  let mut calls = 0
  let mut closed = 0
  let finished = Ref(false)
  builder.build_reschedule(
    fn(caps) {
      held.val = Some(caps[0])
      fn() {
        calls += 1
        !finished.val
      }
    },
    on_shutdown=fn() { closed += 1 },
  )
  let _ = worker.run()
  let mut previous = calls
  let records = []
  for round in 0..<48 {
    if round == seed % 24 {
      held.val.unwrap().release()
      held.val = None
    }
    if round == seed / 3 % 24 {
      finished.val = true
    }
    activator.activate()
    let _ = worker.run()
    records.push("\{if calls > previous { 1 } else { 0 }},\{closed}")
    previous = calls
  }
  worker.dispose()
  records.join(";")
}
