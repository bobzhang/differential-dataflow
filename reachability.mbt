///|
/// Vertices represent individual operator ports; edges carry timestamp summaries.
pub struct ProgressGraph[T, S] {
  priv domain : SummaryDomain[T, S]
  priv edges : Array[Array[(Int32, S)]]
}

///|
pub fn[T, S] ProgressGraph::ProgressGraph(
  domain : SummaryDomain[T, S],
) -> ProgressGraph[T, S] {
  { domain, edges: [], }
}

///|
pub fn[T, S] ProgressGraph::add_port(self : ProgressGraph[T, S]) -> Int32 {
  let id = self.edges.length()
  self.edges.push([])
  id
}

///|
pub fn[T, S] ProgressGraph::connect(
  self : ProgressGraph[T, S],
  source : Int32,
  target : Int32,
  summary : S,
) -> Unit {
  guard source >= 0 &&
    source < self.edges.length() &&
    target >= 0 &&
    target < self.edges.length() else {
    abort("invalid progress graph port")
  }
  self.edges[source].push((target, summary))
}

///|
pub struct Reachability[T, S] {
  priv domain : SummaryDomain[T, S]
  priv paths : Array[Array[Array[S]]]
}

///|
fn[T, S : Compare] insert_summary(
  domain : SummaryDomain[T, S],
  values : Array[S],
  summary : S,
) -> Bool {
  if values.iter().any(fn(old) { (domain.less_equal)(old, summary) }) {
    return false
  }
  let retained = values.filter(fn(old) { !(domain.less_equal)(summary, old) })
  values.clear()
  for old in retained {
    values.push(old)
  }
  values.push(summary)
  values.sort()
  true
}

///|
/// Compute the minimal summaries of all paths. None means the work bound was hit;
/// a partial reachability graph is never returned as complete.
pub fn[T, S : Compare] ProgressGraph::compile(
  self : ProgressGraph[T, S],
  max_steps~ : Int32 = 1000000,
) -> Reachability[T, S]? {
  guard max_steps >= 0 else {
    abort("reachability work bound must be nonnegative")
  }
  let n = self.edges.length()
  let paths = Array::makei(n, fn(_) { Array::makei(n, fn(_) { [] }) })
  let queue = []
  for port in 0..<n {
    paths[port][port].push(self.domain.identity)
    queue.push((port, port, self.domain.identity))
  }
  let mut head = 0
  let mut steps = 0
  while head < queue.length() {
    if steps >= max_steps {
      return None
    }
    steps += 1
    let (origin, port, summary) = queue[head]
    head += 1
    if paths[origin][port].contains(summary) {
      for (next, edge) in self.edges[port] {
        if (self.domain.compose)(summary, edge) is Some(composed) &&
          insert_summary(self.domain, paths[origin][next], composed) {
          queue.push((origin, next, composed))
        }
      }
    }
  }
  Some({ domain: self.domain, paths, })
}

///|
pub fn[T, S] Reachability::port_count(self : Reachability[T, S]) -> Int32 {
  self.paths.length()
}

///|
pub fn[T, S] Reachability::summaries(
  self : Reachability[T, S],
  source : Int32,
  target : Int32,
) -> Array[S] {
  self.paths[source][target].copy()
}

///|
pub struct ProgressTracker[T, S] {
  priv reachability : Reachability[T, S]
  priv counts : ChangeBatch[(Int32, T)]
  priv mut frontiers : Array[Antichain[T]]
}

///|
pub fn[T : Lattice, S] ProgressTracker::ProgressTracker(
  reachability : Reachability[T, S],
) -> ProgressTracker[T, S] {
  {
    reachability,
    counts: ChangeBatch(),
    frontiers: Array::makei(reachability.port_count(), fn(_) { Antichain([]) }),
  }
}

///|
/// Queue a pointstamp count change. Frontier changes are published by propagate().
pub fn[T : Lattice, S] ProgressTracker::update(
  self : ProgressTracker[T, S],
  port : Int32,
  time : T,
  delta : Int64,
) -> Unit {
  guard port >= 0 && port < self.frontiers.length() else {
    abort("invalid progress tracker port")
  }
  self.counts.update((port, time), delta)
}

///|
pub fn[T : Lattice, S] ProgressTracker::propagate(
  self : ProgressTracker[T, S],
) -> Array[(Int32, T, Int64)] {
  let next = Array::makei(self.frontiers.length(), fn(_) { Antichain([]) })
  for ((origin, time), count) in self.counts.to_array() {
    if count > 0 {
      for destination in 0..<next.length() {
        for summary in self.reachability.paths[origin][destination] {
          if (self.reachability.domain.apply)(summary, time) is Some(at) {
            let _ = next[destination].insert(at)
          }
        }
      }
    }
  }
  let delta : ChangeBatch[(Int32, T)] = ChangeBatch()
  for port in 0..<next.length() {
    for time in self.frontiers[port].elements {
      delta.update((port, time), -1)
    }
    for time in next[port].elements {
      delta.update((port, time), 1)
    }
  }
  self.frontiers = next
  delta.drain().map(fn(u) { (u.0.0, u.0.1, u.1) })
}

///|
pub fn[T : Lattice, S] ProgressTracker::frontier(
  self : ProgressTracker[T, S],
  port : Int32,
) -> Antichain[T] {
  Antichain(self.frontiers[port].elements)
}
