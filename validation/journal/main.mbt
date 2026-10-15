///|
fn main raise {
  let args = @env.args()
  let mode = args[1]
  let path = args[2]
  let codec : @differential.WireCodec[
    @differential.CaptureMessage[String, Int64, Int64],
  ] = @differential.CaptureMessage::codec(
    @differential.WireCodec::json(),
    @differential.WireCodec::json(),
    @differential.WireCodec::json(),
  )
  if mode == "follow" {
    let writer = @capture_journal.CaptureJournal::create(path)
    defer (writer.close() catch { _ => () })
    let reader = @capture_journal.CaptureJournal::open(path)
    defer (reader.close() catch { _ => () })
    let worker = @differential.Worker()
    defer worker.dispose()
    let scope = worker.scope(0L, @differential.SummaryDomain::int64())
    let (input, collection) : (
      @differential.InputSession[String, Int64, Int64],
      @differential.Collection[String, Int64, Int64],
    ) = scope.input()
    let capture = scope.capture_to(
      collection,
      CaptureWriter(
        poll=fn(message) {
          writer.append(message, codec) catch {
            JournalError(message) => abort(message)
          }
          None
        },
        done=fn() { true },
      ),
    )
    let (replay, stream) = scope.replay_from(fn(_) {
      fn() {
        reader.next(codec) catch {
          JournalError(message) => abort(message)
        }
      }
    })
    let seen = []
    let probe = stream.inspect(fn(d, t, r) { seen.push((d, t, r)) })
    let _ = worker.run()
    guard !probe.done() else { abort("empty live journal completed") }
    for epoch in 0L..<24L {
      input.update("数据\u0000", 9007199254740993L)
      input.advance_to(epoch + 1)
      input.flush()
      let _ = worker.run()
      replay.activate()
      let _ = worker.run()
      guard seen.length() == (epoch + 1).to_int() && !probe.less_than(epoch + 1) else {
        abort("live journal did not replay")
      }
    }
    input.close()
    let _ = worker.run()
    replay.activate()
    let _ = worker.run()
    guard capture.is_complete() && replay.is_complete() && probe.done() else {
      abort("live journal did not close")
    }
    writer.close()
    reader.close()
    println("followed")
    return
  }
  if mode == "write" {
    let journal = @capture_journal.CaptureJournal::create(path)
    defer (journal.close() catch { _ => () })
    for epoch in 0L..<24L {
      journal.append(
        Updates([("数据\u0000", epoch, 9007199254740993L)]),
        codec,
      )
      journal.append(
        Progress(
          CaptureProgress(Antichain([epoch]), Antichain([epoch + 1]), [
            (epoch, 1L),
          ]),
        ),
        codec,
      )
    }
    journal.append(
      Progress(CaptureProgress(Antichain([24L]), Antichain([]), [])),
      codec,
    )
    journal.close()
    println("written")
    return
  }
  let journal = @capture_journal.CaptureJournal::open(path)
  defer (journal.close() catch { _ => () })
  if mode == "poison" {
    let first = try {
      let _ = journal.next(codec)
      false
    } catch {
      _ => true
    }
    let second = try {
      let _ = journal.next(codec)
      false
    } catch {
      _ => true
    }
    guard first && second else {
      abort("corrupt journal did not remain failed")
    }
    println("poisoned")
    return
  }
  if mode == "closed" {
    journal.close()
    let _ = journal.next(codec)
    abort("closed journal read succeeded")
  }
  if mode == "readonly" {
    journal.append(Updates([]), codec)
    abort("read-only journal append succeeded")
  }
  let worker = @differential.Worker()
  defer worker.dispose()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (handle, stream) = scope.replay_from(
    fn(_) {
      fn() {
        journal.next(codec) catch {
          JournalError(message) => abort(message)
        }
      }
    },
    messages_per_turn=3,
  )
  let seen = []
  let probe = stream.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let _ = worker.run()
  println(Json((handle.is_complete(), probe.done(), seen)).stringify())
}
