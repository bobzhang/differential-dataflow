///|
fn exercise(early : Bool, columnar : Bool) -> Unit {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (roots, nodes) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let forward = graph.arrange_by_key(fueled=true, columnar~)
  let reverse = graph
    .map(fn(edge) { (edge.1, edge.0) })
    .arrange_by_key(fueled=true, columnar~)
  let fview = forward.view()
  let rview = reverse.view()
  let counts = Array::make(3, 0L)
  let p0 = scope
    .bfs_arranged(fview, nodes)
    .inspect(fn(_, _, diff) { counts[0] += diff })
  let p1 = scope
    .propagate_core(fview, nodes.map(fn(node) { (node, node) }), fn(_) { 0UL })
    .inspect(fn(_, _, diff) { counts[1] += diff })
  let p2 = scope
    .bidijkstra_arranged(fview, rview, nodes.map(fn(node) { (node, 7) }))
    .inspect(fn(_, _, diff) { counts[2] += diff })
  let reader = fview.trace()
  let bounded = reader.frontier(Antichain([1L]), Antichain([24L]))
  let consumer = @differential.Worker()
  let target = consumer.scope(0L, @differential.SummaryDomain::int64())
  let imported = bounded.import_into(target).probe()
  bounded.release()
  reader.release()
  fview.release()
  rview.release()
  forward.release()
  reverse.release()
  for node in 0..<8 {
    edges.insert((node, (node + 1) % 8))
  }
  roots.insert(0)
  for epoch in 0L..<32L {
    edges.update((3, 4), if epoch % 2 == 0 { -1L } else { 1L })
    edges.advance_to(epoch + 1)
    roots.advance_to(epoch + 1)
    edges.flush()
    roots.flush()
    guard worker.run(max_steps=100000) is Quiescent(_) &&
      consumer.run() is Quiescent(_) else {
      abort("lifetime graph stalled")
    }
    guard !p0.less_than(epoch + 1) &&
      !p1.less_than(epoch + 1) &&
      !p2.less_than(epoch + 1) &&
      !imported.less_than(epoch + 1) else {
      abort("lifetime progress stalled")
    }
    let connected = epoch % 2 == 1
    guard counts ==
      [
        if connected {
          8L
        } else {
          4L
        },
        if connected {
          8L
        } else {
          4L
        },
        if connected {
          1L
        } else {
          0L
        },
      ] else {
      abort("lifetime graph result differs")
    }
  }
  if !early {
    edges.close()
    roots.close()
    guard worker.run(max_steps=100000) is Quiescent(_) &&
      consumer.run() is Quiescent(_) &&
      p0.done() &&
      p1.done() &&
      p2.done() &&
      imported.done() else {
      abort("lifetime graph did not close")
    }
  }
  if early {
    worker.drop_dataflow(scope.dataflow_index())
    guard !worker.has_dataflows() &&
      consumer.run() is Quiescent(_) &&
      imported.done() else {
      abort("surviving import did not close after root dataflow cancellation")
    }
  }
  worker.dispose()
  guard consumer.run() is Quiescent(_) && imported.done() else {
    abort("surviving import did not close after producer disposal")
  }
  consumer.dispose()
}

///|
fn main {
  for iteration in 0..<8 {
    exercise(false, iteration % 2 == 0)
    exercise(true, iteration % 2 == 0)
  }
  println("graph and trace lifetimes passed")
}
