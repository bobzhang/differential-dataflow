///|
#export_name("evaluate_search")
pub fn evaluate_search(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (goals, queries) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (input, states) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let observed : Map[(Int32, Int32, Int32, Int64), Int64] = Map([])
  let p0 = scope
    .bidijkstra(graph, queries)
    .inspect(fn(data, _, diff) {
      let key = (0, data.0.0, data.0.1, data.1.to_int64())
      observed[key] = observed.get(key).unwrap_or(0L) + diff
    })
  let p1 = scope
    .sequence(states, graph, fn(_, values) {
      values
      .iter()
      .fold(init=1, fn(sum, value) { sum + value.0 * value.1.to_int() })
    })
    .inspect(fn(data, _, diff) {
      let key = (1, data.0, 0, data.1.unwrap_or(-1).to_int64())
      observed[key] = observed.get(key).unwrap_or(0L) + diff
    })
  let weights = Array::make(25, 0L)
  let requests = Array::make(25, 0L)
  let values = Array::makei(5, fn(i) { i + 1 })
  for i in 0..<5 {
    input.insert((i, values[i]))
  }
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for epoch in 0L..<12L {
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 25U).reinterpret_as_int()
      let next = if weights[index] == 0L {
        (random % 2U).to_int64() + 1L
      } else {
        0L
      }
      edges.update((index / 5, index % 5), next - weights[index])
      weights[index] = next
    }
    for _ in 0..<2 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 25U).reinterpret_as_int()
      let next = if requests[index] == 0L {
        (random % 2U).to_int64() + 1L
      } else {
        0L
      }
      goals.update((index / 5, index % 5), next - requests[index])
      requests[index] = next
    }
    random = random * 1664525U + 1013904223U
    let node = ((random >> 8) % 5U).reinterpret_as_int()
    input.remove((node, values[node]))
    values[node] = (random % 9U).reinterpret_as_int() + 1
    input.insert((node, values[node]))
    edges.advance_to(epoch + 1)
    goals.advance_to(epoch + 1)
    input.advance_to(epoch + 1)
    edges.flush()
    goals.flush()
    input.flush()
    guard worker.run(max_steps=100000) is Quiescent(_) &&
      !p0.less_than(epoch + 1) &&
      !p1.less_than(epoch + 1) else {
      abort("graph search convergence")
    }
    let rows = observed.to_array().filter(fn(x) { x.1 != 0L })
    rows.sort()
    output.push(
      rows.map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.0.3},\{x.1}" }).join(";"),
    )
  }
  edges.close()
  goals.close()
  input.close()
  guard worker.run() is Quiescent(_) && p0.done() && p1.done() else {
    abort("graph search closure")
  }
  worker.dispose()
  "GRAPH_SEARCH|" + output.join("/")
}
