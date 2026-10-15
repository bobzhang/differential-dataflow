///|
/// Nonblocking host adapter. start submits one immutable round payload; poll
/// returns None while pending or one peer-ordered response. Only one round is
/// outstanding. Both callbacks run on the owning worker thread.
pub struct AsyncExchange {
  priv start : (String) -> Unit raise
  priv poll : () -> Array[String]? raise
}

///|
pub fn AsyncExchange::AsyncExchange(
  start~ : (String) -> Unit raise,
  poll~ : () -> Array[String]? raise,
) -> AsyncExchange {
  { start, poll, }
}

///|
priv enum ExchangeDriver {
  Blocking((String) -> Array[String] raise)
  Polling(AsyncExchange)
}

///|
priv struct ClusterRound {
  payload : String
  shape : (Int32, Int32, Int32, Int32)
  manifest : Json
}

///|
/// Pending yields to the host; Progress completed a collective round with work;
/// Quiescent completed a round with no globally scheduled or in-flight work.
pub(all) enum ClusterPoll {
  Pending
  Progress
  Quiescent
} derive(Eq, Debug)

///|
pub extend ClusterPoll with Eq::{equal, not_equal}

///|
pub extend ClusterPoll with Debug::{to_repr}

///|
/// Advance one collective round, yielding while asynchronous I/O is pending.
/// Operators run when a complete round can publish globally counted progress.
/// Build graphs and submit input epochs before driving every peer to Quiescent.
/// Pending does not mean the input or its output frontier is complete.
pub fn ClusterWorker::poll(self : ClusterWorker) -> ClusterPoll raise {
  guard !self.state.closed else {
    raise ClusterError("cluster worker is closed")
  }
  guard !self.state.running else {
    raise ClusterError("cluster polling cannot re-enter")
  }
  self.state.running = true
  defer {
    self.state.running = false
  }
  errdefer self.dispose()
  let completed = match self.state.pending {
    None => {
      let round = self.prepare_round()
      match self.exchange {
        Blocking(exchange) => Some((round, exchange(round.payload)))
        Polling(exchange) => {
          self.state.pending = Some(round)
          (exchange.start)(round.payload)
          None
        }
      }
    }
    Some(round) => {
      guard self.exchange is Polling(exchange) else {
        abort("invalid pending blocking exchange")
      }
      match (exchange.poll)() {
        None => None
        Some(values) => {
          self.state.pending = None
          Some((round, values))
        }
      }
    }
  }
  match completed {
    None => Pending
    Some((round, values)) =>
      if self.apply_round(round, values) {
        Progress
      } else {
        Quiescent
      }
  }
}
