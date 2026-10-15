///|
// Each domain retains its concrete timestamp type. Boundary closures carry only
// antichains, so no timestamp erasure or synthetic capability is necessary.
priv struct ProgressDomain {
  prepare : () -> Bool
  seed : () -> Unit
  publish : () -> Unit
}

///|
priv struct ProgressNetwork {
  domains : Array[ProgressDomain]
  links : Array[() -> Bool]
  topology : Array[(Int32, Int32, Int32, Int32)]
  mut workers : Int32
}

///|
fn ProgressNetwork::ProgressNetwork() -> ProgressNetwork {
  { domains: [], links: [], topology: [], workers: 0, }
}

///|
fn ProgressNetwork::pump(self : ProgressNetwork) -> Unit {
  let mut changed = false
  for domain in self.domains {
    // Do not short-circuit: all count transactions precede propagation.
    let prepared = (domain.prepare)()
    changed = changed || prepared
  }
  if !changed {
    return
  }
  for domain in self.domains {
    (domain.seed)()
  }
  let mut steps = 0
  for ;; {
    let mut advanced = false
    for transfer in self.links {
      let moved = transfer()
      advanced = advanced || moved
    }
    if !advanced {
      break
    }
    steps += 1
    guard steps < 1000000 else {
      abort("cross-scope reachability did not converge")
    }
  }
  // Observers see only the global fixed point, never an intermediate frontier.
  for domain in self.domains {
    (domain.publish)()
  }
}

///|
fn[A, B : Lattice, S, U] ProgressNetwork::link(
  self : ProgressNetwork,
  source : ScopeProgress[A, S],
  input : Int32,
  target : ScopeProgress[B, U],
  output : Int32,
  translate : (A) -> B,
) -> Unit {
  self.topology.push((source.id, input, target.id, output))
  self.links.push(fn() {
    if source.disposed || target.disposed {
      return false
    }
    let times = source.transient[input].elements.map(translate)
    target.include_frontier(output, times)
  })
}
