///|
/// A typed, buffered logger. Publish owns its batch. Call flush at host polling
/// boundaries; reaching capacity also flushes. The supplied clock is monotone.
pub struct Logger[E] {
  priv clock : () -> Duration
  priv publish : (Duration, Array[(Duration, E)]) -> Unit
  priv capacity : Int32
  priv mut pending : Array[(Duration, E)]
  priv mut last_time : Duration
  priv mut publishing : Bool
}

///|
pub fn[E] Logger::Logger(
  clock~ : () -> Duration,
  publish~ : (Duration, Array[(Duration, E)]) -> Unit,
  capacity~ : Int32 = 1024,
) -> Logger[E] {
  guard capacity > 0 else { abort("logger capacity must be positive") }
  {
    clock,
    publish,
    capacity,
    pending: [],
    last_time: Duration(0UL),
    publishing: false,
  }
}

///|
fn[E] Logger::now(self : Logger[E]) -> Duration {
  let now = (self.clock)()
  guard now >= self.last_time else { abort("logging clock moved backward") }
  self.last_time = now
  now
}

///|
pub fn[E] Logger::log(self : Logger[E], event : E) -> Unit {
  self.pending.push((self.now(), event))
  if self.pending.length() >= self.capacity && !self.publishing {
    self.flush()
  }
}

///|
/// Publish the current batch once, including an empty batch to advance logging
/// time without new events. Events logged by the callback stay queued for
/// the next flush, so a callback cannot cause recursive publication.
pub fn[E] Logger::flush(self : Logger[E]) -> Unit {
  guard !self.publishing else { return }
  let now = self.now()
  let batch = self.pending
  self.pending = []
  self.publishing = true
  (self.publish)(now, batch)
  self.publishing = false
}

///|
pub fn[E] Logger::pending(self : Logger[E]) -> Int32 {
  self.pending.length()
}

///|
/// Typed logging registry. Replacement/removal affects future lookups; retained
/// logger handles continue publishing to their original sink.
pub struct LogRegistry[E] {
  priv loggers : Map[String, Logger[E]]
}

///|
pub fn[E] LogRegistry::LogRegistry() -> LogRegistry[E] {
  { loggers: Map([]), }
}

///|
pub fn[E] LogRegistry::insert(
  self : LogRegistry[E],
  name : String,
  logger : Logger[E],
) -> Logger[E]? {
  let old = self.loggers.get(name)
  self.loggers[name] = logger
  old
}

///|
pub fn[E] LogRegistry::get(self : LogRegistry[E], name : String) -> Logger[E]? {
  self.loggers.get(name)
}

///|
pub fn[E] LogRegistry::remove(
  self : LogRegistry[E],
  name : String,
) -> Logger[E]? {
  let old = self.loggers.get(name)
  self.loggers.remove(name)
  old
}

///|
pub fn[E] LogRegistry::flush(self : LogRegistry[E]) -> Unit {
  // Callbacks may replace entries without invalidating this traversal.
  for (_, logger) in self.loggers.to_array() {
    logger.flush()
  }
}

///|
pub(all) struct BatchEvent {
  operator : Int32
  length : Int32
} derive(Eq, Debug)

///|
pub(all) struct MergeEvent {
  operator : Int32
  scale : Int32
  length1 : Int32
  length2 : Int32
  complete : Int32?
} derive(Eq, Debug)

///|
pub(all) struct DropEvent {
  operator : Int32
  length : Int32
} derive(Eq, Debug)

///|
pub(all) struct MergeShortfall {
  operator : Int32
  scale : Int32
  shortfall : Int32
} derive(Eq, Debug)

///|
pub(all) struct TraceShare {
  operator : Int32
  diff : Int32
} derive(Eq, Debug)

///|
/// Record deltas are exact. Byte/capacity/allocation deltas are optional because
/// managed backends do not expose allocator accounting. None means unavailable,
/// never zero bytes. Custom storage can emit measurements in these fields.
pub(all) struct BatcherEvent {
  operator : Int32
  records_diff : Int32
  size_diff : Int64?
  capacity_diff : Int64?
  allocations_diff : Int64?
} derive(Eq, Debug)

///|
pub(all) enum DifferentialEvent {
  BatchCreated(BatchEvent)
  MergeProgress(MergeEvent)
  BatchDropped(DropEvent)
  MergeShortfall(MergeShortfall)
  TraceShare(TraceShare)
  BatcherSize(BatcherEvent)
} derive(Eq, Debug)

///|
/// Bind trace diagnostics to a worker-local operator identity.
pub struct TraceLogger {
  priv logger : Logger[DifferentialEvent]
  priv operator : Int32
}

///|
pub fn TraceLogger::TraceLogger(
  logger : Logger[DifferentialEvent],
  operator~ : Int32,
) -> TraceLogger {
  { logger, operator, }
}

///|
fn TraceLogger::batch(self : TraceLogger, length : Int32) -> Unit {
  self.logger.log(BatchCreated({ operator: self.operator, length, }))
}

///|
fn TraceLogger::merge(
  self : TraceLogger,
  length1 : Int32,
  length2 : Int32,
  complete : Int32?,
) -> Unit {
  let mut scale = 0
  let mut size = Int32::max(1, Int32::max(length1, length2)) - 1
  while size > 0 {
    size = size >> 1
    scale += 1
  }
  self.logger.log(
    MergeProgress({
      operator: self.operator,
      scale,
      length1,
      length2,
      complete,
    }),
  )
}

///|
fn TraceLogger::drop_batch(self : TraceLogger, length : Int32) -> Unit {
  self.logger.log(BatchDropped({ operator: self.operator, length, }))
}

///|
fn TraceLogger::share(self : TraceLogger, diff : Int32) -> Unit {
  self.logger.log(TraceShare({ operator: self.operator, diff, }))
}

///|
fn TraceLogger::batcher(self : TraceLogger, records_diff : Int32) -> Unit {
  if records_diff != 0 {
    self.logger.log(
      BatcherSize({
        operator: self.operator,
        records_diff,
        size_diff: None,
        capacity_diff: None,
        allocations_diff: None,
      }),
    )
  }
}

///|
/// Register differential events under "differential/arrange" before building
/// arrangements. Existing operators retain the logger captured at construction.
pub fn Worker::differential_logs(
  self : Worker,
) -> LogRegistry[DifferentialEvent] {
  self.logs
}

///|
pub extend BatchEvent with Eq::{equal, not_equal}

///|
pub extend BatchEvent with Debug::{to_repr}

///|
pub extend MergeEvent with Eq::{equal, not_equal}

///|
pub extend MergeEvent with Debug::{to_repr}

///|
pub extend DropEvent with Eq::{equal, not_equal}

///|
pub extend DropEvent with Debug::{to_repr}

///|
pub extend MergeShortfall with Eq::{equal, not_equal}

///|
pub extend MergeShortfall with Debug::{to_repr}

///|
pub extend TraceShare with Eq::{equal, not_equal}

///|
pub extend TraceShare with Debug::{to_repr}

///|
pub extend BatcherEvent with Eq::{equal, not_equal}

///|
pub extend BatcherEvent with Debug::{to_repr}

///|
pub extend DifferentialEvent with Eq::{equal, not_equal}

///|
pub extend DifferentialEvent with Debug::{to_repr}

///|
/// Record a group of events with one timestamp before publication.
pub fn[E] Logger::log_many(self : Logger[E], events : Array[E]) -> Unit {
  let time = self.now()
  for event in events {
    self.pending.push((time, event))
  }
  if self.pending.length() >= self.capacity && !self.publishing {
    self.flush()
  }
}
