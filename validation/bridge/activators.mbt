///|
#export_name("evaluate_activators")
pub fn evaluate_activators(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activator = builder.activator()
  let (_, _stream) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  let mut count = 0
  let held : Ref[@differential.Capability[Int64, Int64]?] = Ref(None)
  builder.build(fn(caps) {
    held.val = Some(caps[0])
    fn() { count += 1 }
  })
  let _ = worker.run()
  let baseline = count
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for _ in 0..<64 {
    random = random * 1664525U + 1013904223U
    for _ in 0..<((random >> 8) % 7U).reinterpret_as_int() {
      if random % 2U == 0U {
        activator.activate()
      } else {
        activator.activate_after(Duration(0UL))
      }
    }
    let _ = worker.run()
    output.push("\{count - baseline}")
  }
  held.val.unwrap().release()
  worker.dispose()
  output.join(",")
}
