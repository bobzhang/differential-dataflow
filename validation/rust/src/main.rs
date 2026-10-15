mod envelopes;
mod monoid_bfs;
mod core_presence;
mod pointstamp;
mod cancellation;
mod examples;
mod replay_distributed;
mod capture_async;
mod dynamic;
mod lifecycle;
mod columnar;
mod activators;
mod spines;
mod batches;
mod cursors;
mod search;
mod identifiers;
mod prefix;
use differential_dataflow::lattice::Lattice;
use std::io::{self, BufRead};
use timely::order::Product;
use timely::progress::{frontier::MutableAntichain, Antichain};
fn evaluate(seed: u32) -> String {
    let mut random = seed;
    let mut frontier = MutableAntichain::<Product<i64, i64>>::new();
    let mut result = Vec::new();
    for _ in 0..40 {
        let mut updates = Vec::new();
        for _ in 0..3 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = ((random >> 8) % 25) as i64;
            let delta = if random % 3 == 0 { -1 } else { 1 };
            updates.push((Product::new(index / 5, index % 5), delta));
        }
        let mut changes: Vec<_> = frontier.update_iter(updates).collect();
        changes.sort();
        let mut minimal = frontier.frontier().to_vec();
        minimal.sort();
        let antichain: Antichain<_> = minimal.iter().cloned().collect();
        let mut time = Product::new((seed % 5) as i64, ((seed / 5) % 5) as i64);
        time.advance_by(antichain.borrow());
        result.push(format!(
            "{}|{}|{},{}",
            changes
                .iter()
                .map(|(t, d)| format!("{},{},{}", t.outer, t.inner, d))
                .collect::<Vec<_>>()
                .join(";"),
            minimal
                .iter()
                .map(|t| format!("{},{}", t.outer, t.inner))
                .collect::<Vec<_>>()
                .join(";"),
            time.outer,
            time.inner
        ));
    }
    result.join("/")
}
fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    for line in io::stdin().lock().lines() {
        let seed = line.unwrap().parse().unwrap();
        println!(
            "{}",
            match mode.as_str() {
                "examples" => examples::evaluate(seed),
                "cancellation" => cancellation::evaluate(seed),
                "pointstamp" => pointstamp::evaluate(seed),
                "dynamic_iteration" => pointstamp::iterate(seed),
                "spilled_spines" => columnar::spilled(seed),
                "columnar_spines" => columnar::evaluate(seed),
                "eager_replay" => capture_async::eager(seed),
                "group_replay" => replay_distributed::evaluate(seed),
                "capture_async" => capture_async::evaluate(seed),
                "dynamic" => dynamic::evaluate(seed),
                "lifecycle" => lifecycle::evaluate(seed),
                "activators" => activators::evaluate(seed),
                "spines" => spines::evaluate(seed),
                "batches" => batches::evaluate(seed),
                "trace_views" => cursors::views(seed),
                "cursors" => cursors::evaluate(seed),
                "numeric" => evaluate_numeric(seed),
                "graphs" => evaluate_graphs(seed),
                "prefix" => prefix::evaluate(seed),
                "identifiers" => identifiers::evaluate(seed),
                "search" => search::evaluate(seed),
                "join" => evaluate_join(seed),
                "reduce" => evaluate_reduce(seed),
                "stream_reduce" => evaluate_stream_reduce(seed, false),
                "core_reduce" => evaluate_stream_reduce(seed, true),
                "core_presence" => core_presence::evaluate(seed),
                "monoid_bfs" => monoid_bfs::evaluate(seed),
                "envelopes" => envelopes::evaluate(seed),
                "feedback" => evaluate_feedback(seed, false),
                "signed_feedback" => evaluate_feedback(seed, true),
                "iteration" => evaluate_iteration(seed),
                "arrangement" => evaluate_arrangement(seed),
                "upsert" => evaluate_upsert(seed),
                "replay" => evaluate_replay(seed),
                "group_join" => evaluate_group_join(seed),
                _ => evaluate(seed),
            }
        );
    }
}
fn evaluate_join(seed: u32) -> String {
    use differential_dataflow::input::Input;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::rc::Rc;
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32, u32, u32), i64>::new()));
        let sink = observed.clone();
        let (mut a, mut b, probe) = worker.dataflow::<u64, _, _>(|scope| {
            let (a, left) = scope.new_collection::<(u32, u32), i64>();
            let (b, right) = scope.new_collection::<(u32, u32), i64>();
            let (probe, _) = left
                .join(right)
                .consolidate()
                .inspect(move |&((k, (v, w)), _, diff)| {
                    *sink.borrow_mut().entry((k, v, w)).or_default() += diff;
                })
                .probe();
            (a, b, probe)
        });
        let mut random = seed;
        let mut results = Vec::new();
        for epoch in 0..16 {
            for side in 0..2 {
                for _ in 0..4 {
                    random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                    let index = (random >> 8) % 20;
                    let diff = (random % 5) as i64 - 2;
                    let data = (index / 5, index % 5);
                    if side == 0 {
                        a.update(data, diff);
                    } else {
                        b.update(data, diff);
                    }
                }
            }
            a.advance_to(epoch + 1);
            b.advance_to(epoch + 1);
            a.flush();
            b.flush();
            while probe.less_than(a.time()) {
                worker.step();
            }
            results.push(
                observed
                    .borrow()
                    .iter()
                    .filter(|(_, d)| **d != 0)
                    .map(|(&(k, v, w), d)| format!("{k},{v},{w},{d}"))
                    .collect::<Vec<_>>()
                    .join(";"),
            );
        }
        a.close();
        b.close();
        while !probe.done() {
            worker.step();
        }
        results.join("/")
    })
}

fn evaluate_reduce(seed: u32) -> String {
    use differential_dataflow::AsCollection;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::rc::Rc;
    use timely::dataflow::operators::ToStream;
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(
            BTreeMap::<(u32, u32, i64, u64, u64), i64>::new(),
        ));
        let sinks = [observed.clone(), observed.clone(), observed.clone()];
        let mut random = seed;
        let mut updates = Vec::new();
        for _ in 0..32 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = (random >> 8) % 375;
            updates.push((
                (index / 125, index % 5),
                Product::new((index / 25 % 5) as u64, (index / 5 % 5) as u64),
                (random % 5) as i64 - 2,
            ));
        }
        let probes = worker.dataflow::<u64, _, _>(|outer| {
            outer.scoped::<Product<u64, u64>, _, _>("ReduceCheck", |scope| {
                let collection = updates.to_stream(scope).as_collection();
                let [s0, s1, s2] = sinks;
                let (p0, _) = collection
                    .clone()
                    .map(|(k, _)| k)
                    .distinct_core::<i64>()
                    .inspect(move |&(k, t, d)| {
                        *s0.borrow_mut()
                            .entry((0, k, 0, t.outer, t.inner))
                            .or_default() += d;
                    })
                    .probe();
                let (p1, _) = collection
                    .clone()
                    .map(|(k, _)| k)
                    .count()
                    .inspect(move |&((k, v), t, d)| {
                        *s1.borrow_mut()
                            .entry((1, k, v, t.outer, t.inner))
                            .or_default() += d as i64;
                    })
                    .probe();
                let (p2, _) = collection
                    .reduce(|_k, values, output| output.push((*values[0].0, 1i64)))
                    .inspect(move |&((k, v), t, d)| {
                        *s2.borrow_mut()
                            .entry((2, k, v as i64, t.outer, t.inner))
                            .or_default() += d;
                    })
                    .probe();
                [p0, p1, p2]
            })
        });
        while probes.iter().any(|p| !p.done()) {
            worker.step();
        }
        let result = observed
            .borrow()
            .iter()
            .filter(|(_, d)| **d != 0)
            .map(|(&(op, k, v, x, y), d)| format!("{op},{k},{v},{x},{y},{d}"))
            .collect::<Vec<_>>()
            .join(";");
        result
    })
}

fn evaluate_feedback(seed: u32, split: bool) -> String {
    use differential_dataflow::{input::Input, operators::iterate::VecVariable};
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32, i64), i64>::new()));
        let sink = observed.clone();
        let delay = (seed % 3 + 1) as i64;
        let (mut input, probe) = worker.dataflow::<i64, _, _>(|scope| {
            let (input, values) = scope.new_collection::<u32, i64>();
            let (feedback, looped) = VecVariable::new(scope, delay + if split { 7 } else { 0 });
            let looped = if split {
                let (backward, lowered) = VecVariable::new(scope, -7i64);
                backward.set(looped);
                lowered
            } else { looped };
            let all = values.concat(looped);
            feedback.set(all.clone().map(|x| x + 1).filter(|x| *x < 12).consolidate());
            let (probe, _) = all
                .consolidate()
                .inspect(move |&(d, t, r)| {
                    *sink.borrow_mut().entry((d, t)).or_default() += r;
                })
                .probe();
            (input, probe)
        });
        input.advance_to(0);
        let mut random = seed;
        let mut result = Vec::new();
        for epoch in 0..4 {
            for _ in 0..8 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                input.update((random >> 8) % 8, (random % 5) as i64 - 2);
            }
            input.advance_to((epoch + 1) * 64);
            input.flush();
            while probe.less_than(input.time()) {
                worker.step();
            }
            result.push(
                observed
                    .borrow()
                    .iter()
                    .filter(|(_, r)| **r != 0)
                    .map(|(&(d, t), r)| format!("{d},{t},{r}"))
                    .collect::<Vec<_>>()
                    .join(";"),
            );
        }
        input.close();
        while !probe.done() {
            worker.step();
        }
        result.join("/")
    })
}

fn evaluate_iteration(seed: u32) -> String {
    use differential_dataflow::{input::Input, operators::Iterate};
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    timely::execute_directly(move |worker| {
        let mut random = seed;
        let mut edges = vec![Vec::new(); 6];
        for _ in 0..12 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = (random >> 8) % 36;
            edges[(index / 6) as usize].push(index % 6);
        }
        let observed = Rc::new(RefCell::new(BTreeMap::<u32, i64>::new()));
        let sink = observed.clone();
        let (mut input, probe) = worker.dataflow::<u64, _, _>(|scope| {
            let (input, source) = scope.new_collection::<u32, i64>();
            let result = source.iterate(move |_, values| {
                values
                    .clone()
                    .concat(values.flat_map(move |x| edges[x as usize].clone()))
                    .distinct_core::<i64>()
            });
            let (probe, _) = result
                .consolidate()
                .inspect(move |&(d, _, r)| {
                    *sink.borrow_mut().entry(d).or_default() += r;
                })
                .probe();
            (input, probe)
        });
        let mut roots = [false; 6];
        let mut result = Vec::new();
        for epoch in 0..8 {
            for _ in 0..2 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let key = ((random >> 8) % 6) as usize;
                roots[key] = !roots[key];
                input.update(key as u32, if roots[key] { 1 } else { -1 });
            }
            input.advance_to(epoch + 1);
            input.flush();
            while probe.less_than(input.time()) {
                worker.step();
            }
            result.push(
                observed
                    .borrow()
                    .iter()
                    .filter(|(_, r)| **r != 0)
                    .map(|(d, r)| format!("{d},{r}"))
                    .collect::<Vec<_>>()
                    .join(";"),
            );
        }
        input.close();
        while !probe.done() {
            worker.step();
        }
        result.join("/")
    })
}

fn evaluate_arrangement(seed: u32) -> String {
    use differential_dataflow::{
        input::Input,
        trace::{Cursor, TraceReader},
    };
    timely::execute_directly(move |worker| {
        let (mut input, mut trace, probe) = worker.dataflow::<u64, _, _>(|scope| {
            let (input, values) = scope.new_collection::<(u32, u32), i64>();
            let arranged = values.arrange_by_key();
            let trace = arranged.trace.clone();
            let (probe, _) = arranged.as_collection(|k, v| (*k, *v)).probe();
            (input, trace, probe)
        });
        let mut slow = trace.clone();
        let mut random = seed;
        let mut result = Vec::new();
        for epoch in 0..16 {
            for _ in 0..6 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = (random >> 8) % 12;
                input.update((index / 4, index % 4), (random % 5) as i64 - 2);
            }
            input.advance_to(epoch + 1);
            input.flush();
            while probe.less_than(input.time()) {
                worker.step();
            }
            let past = epoch / 4 * 4;
            trace.set_logical_compaction(Antichain::from_elem(epoch).borrow());
            trace.set_physical_compaction(Antichain::from_elem(epoch + 1).borrow());
            slow.set_logical_compaction(Antichain::from_elem(past).borrow());
            slow.set_physical_compaction(Antichain::from_elem(past).borrow());
            let mut snapshots = Vec::new();
            for query in [past, epoch] {
                let (mut cursor, storage) = slow.cursor();
                let mut records = Vec::new();
                while cursor.key_valid(&storage) {
                    while cursor.val_valid(&storage) {
                        let mut count = 0i64;
                        cursor.map_times(&storage, |t, r| {
                            if *t <= query {
                                count += *r
                            }
                        });
                        if count != 0 {
                            records.push(format!(
                                "{},{},{}",
                                cursor.key(&storage),
                                cursor.val(&storage),
                                count
                            ));
                        }
                        cursor.step_val(&storage);
                    }
                    cursor.step_key(&storage);
                }
                snapshots.push(records.join(";"));
            }
            result.push(snapshots.join("|"));
        }
        input.close();
        while !probe.done() {
            worker.step();
        }
        result.join("/")
    })
}

fn evaluate_upsert(seed: u32) -> String {
    use differential_dataflow::{
        operators::arrange::upsert::arrange_from_upsert,
        trace::implementations::{ValBuilder, ValSpine},
    };
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    use timely::dataflow::operators::ToStream;
    timely::execute_directly(move |worker| {
        let mut random = seed;
        let mut updates = Vec::new();
        for _ in 0..64 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = (random >> 8) % 256;
            updates.push((
                index / 64,
                if random % 4 == 0 {
                    None
                } else {
                    Some(index % 8)
                },
                (index / 8 % 8) as u64,
            ));
        }
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32, u32, u64), i64>::new()));
        let sink = observed.clone();
        let probe = worker.dataflow::<u64, _, _>(|scope| {
            let arranged = arrange_from_upsert::<
                ValBuilder<u32, u32, u64, isize>,
                ValSpine<u32, u32, u64, isize>,
                u32,
                u32,
            >(updates.to_stream(scope), "UpsertCheck");
            let (probe, _) = arranged
                .as_collection(|k, v| (*k, *v))
                .inspect(move |&((k, v), t, r)| {
                    *sink.borrow_mut().entry((k, v, t)).or_default() += r as i64;
                })
                .probe();
            probe
        });
        while !probe.done() {
            worker.step();
        }
        let result = observed
            .borrow()
            .iter()
            .filter(|(_, r)| **r != 0)
            .map(|(&(k, v, t), r)| format!("{k},{v},{t},{r}"))
            .collect::<Vec<_>>()
            .join(";");
        result
    })
}

fn evaluate_replay(seed: u32) -> String {
    use differential_dataflow::capture::{iterator::Iter, Message, Progress};
    let mut random = seed;
    let mut messages = Vec::new();
    for epoch in 0u64..8 {
        random = random.wrapping_mul(1664525).wrapping_add(1013904223);
        let data = (random >> 8) % 11;
        let diff = (random % 3 + 1) as i64;
        messages.push(Message::Updates(vec![
            (data, epoch, diff),
            (data + 20, epoch, -diff),
        ]));
        messages.push(Message::Progress(Progress {
            lower: vec![epoch],
            upper: vec![epoch + 1],
            counts: vec![(epoch, 2)],
        }));
    }
    messages.push(Message::Progress(Progress {
        lower: vec![8],
        upper: vec![],
        counts: vec![],
    }));
    messages.extend(messages.clone());
    for index in 1..messages.len() {
        random = random.wrapping_mul(1664525).wrapping_add(1013904223);
        messages.swap(index, random as usize % (index + 1));
    }
    Iter::new(messages.into_iter())
        .map(|(mut updates, frontier)| {
            updates.sort();
            format!(
                "{}|{}",
                updates
                    .iter()
                    .map(|(d, t, r)| format!("{d},{t},{r}"))
                    .collect::<Vec<_>>()
                    .join(";"),
                frontier
                    .elements()
                    .iter()
                    .map(|t| t.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            )
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn evaluate_group_join(seed: u32) -> String {
    use differential_dataflow::input::Input;
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    let guards = timely::execute(timely::Config::process(2), move |worker| {
        let peer = worker.index();
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32, u32, u32), i64>::new()));
        let sink = observed.clone();
        let (mut a, mut b, probe) = worker.dataflow::<u64, _, _>(|scope| {
            let (a, left) = scope.new_collection::<(u32, u32), i64>();
            let (b, right) = scope.new_collection::<(u32, u32), i64>();
            let (probe, _) = left
                .join(right)
                .consolidate()
                .inspect(move |&((k, (v, w)), _, r)| {
                    *sink.borrow_mut().entry((k, v, w)).or_default() += r;
                })
                .probe();
            (a, b, probe)
        });
        let mut random = seed;
        let mut snapshots = Vec::new();
        for epoch in 0..16 {
            for side in 0..2 {
                for _ in 0..4 {
                    random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                    let index = (random >> 8) % 20;
                    if ((random >> 16) % 2) as usize == peer {
                        let diff = (random % 5) as i64 - 2;
                        if side == 0 {
                            a.update((index / 5, index % 5), diff);
                        } else {
                            b.update((index / 5, index % 5), diff);
                        }
                    }
                }
            }
            a.advance_to(epoch + 1);
            b.advance_to(epoch + 1);
            a.flush();
            b.flush();
            while probe.less_than(a.time()) {
                worker.step();
            }
            snapshots.push(observed.borrow().clone());
        }
        a.close();
        b.close();
        while !probe.done() {
            worker.step();
        }
        snapshots
    })
    .unwrap();
    let peers = guards
        .join()
        .into_iter()
        .map(Result::unwrap)
        .collect::<Vec<_>>();
    (0..16)
        .map(|epoch| {
            let mut merged = BTreeMap::new();
            for peer in &peers {
                for (key, diff) in &peer[epoch] {
                    *merged.entry(*key).or_insert(0i64) += *diff;
                }
            }
            merged
                .iter()
                .filter(|(_, r)| **r != 0)
                .map(|(&(k, v, w), r)| format!("{k},{v},{w},{r}"))
                .collect::<Vec<_>>()
                .join(";")
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn evaluate_stream_reduce(seed: u32, core: bool) -> String {
    use differential_dataflow::AsCollection;
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    use timely::dataflow::operators::vec::UnorderedInput;
    use timely::order::PartialOrder;
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(i64, u64, u64), i64>::new()));
        let sink = observed.clone();
        let ((mut input, initial), probe) = worker.dataflow::<u64, _, _>(|outer| {
            outer.scoped::<Product<u64, u64>, _, _>("StreamReduce", |scope| {
                let (input, stream) =
                    scope.new_unordered_input::<((u32, u32), Product<u64, u64>, i64)>();
                let collection = stream.as_collection().map(|(k,v)| (k, v as i64));
                let reduced = if core {
                    use differential_dataflow::trace::implementations::{ValBuilder, ValSpine};
                    collection.reduce_core::<_, ValBuilder<u32, i64, Product<u64,u64>, i64>, ValSpine<u32,i64,Product<u64,u64>,i64>>(
                        "CoreReduce", |_, values, previous, changes| {
                            if !values.is_empty() { changes.push((values.iter().map(|x|x.1).sum::<i64>(),1i64)); }
                            changes.extend(previous.drain(..).map(|(v,r)|(v,-r)));
                            differential_dataflow::consolidation::consolidate(changes);
                        }).as_collection(|k,v| (*k,*v))
                } else {
                    collection.reduce(|_, values, output| {
                        output.push((values.iter().map(|x| x.1).sum::<i64>(), 1i64))
                    })
                };
                let (probe, _) = reduced
                    .inspect(move |&((_, value), time, diff)| {
                        *sink
                            .borrow_mut()
                            .entry((value, time.outer, time.inner))
                            .or_default() += diff;
                    })
                    .probe();
                (input, probe)
            })
        });
        let mut caps = vec![initial];
        let mut random = seed;
        let mut results = Vec::new();
        for epoch in 0..24u64 {
            for side in 0..2 {
                let time = if side == 0 {
                    Product::new(epoch, epoch + 1)
                } else {
                    Product::new(epoch + 1, epoch)
                };
                let cap = caps
                    .iter()
                    .find(|c| c.time().less_equal(&time))
                    .unwrap()
                    .delayed(&time);
                for _ in 0..3 {
                    random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                    input.activate().session(&cap).give((
                        (0, (random >> 8) % 4),
                        time,
                        (random % 5) as i64 - 2,
                    ));
                }
            }
            let frontier: Antichain<_> = [
                Product::new(epoch + 2, epoch),
                Product::new(epoch, epoch + 2),
            ]
            .into_iter()
            .collect();
            caps = frontier
                .elements()
                .iter()
                .map(|time| {
                    caps.iter()
                        .find(|c| c.time().less_equal(time))
                        .unwrap()
                        .delayed(time)
                })
                .collect();
            while probe.with_frontier(|f| f.iter().any(|t| !frontier.less_equal(t))) {
                worker.step();
            }
            results.push(
                observed
                    .borrow()
                    .iter()
                    .filter(|((_, x, y), d)| {
                        **d != 0 && !frontier.less_equal(&Product::new(*x, *y))
                    })
                    .map(|((v, x, y), d)| format!("{v},{x},{y},{d}"))
                    .collect::<Vec<_>>()
                    .join(";"),
            );
        }
        drop(caps);
        while !probe.done() {
            worker.step();
        }
        results.join("/")
    })
}

fn evaluate_numeric(seed: u32) -> String {
    fn next(state: &mut u32) -> u64 {
        *state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        let high = *state as u64;
        *state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        (high << 32) | *state as u64
    }
    let mut random = seed;
    (0..64)
        .map(|_| {
            let ah = next(&mut random);
            let al = next(&mut random);
            let bh = next(&mut random);
            let bl = next(&mut random);
            let u = ((ah as u128) << 64) | al as u128;
            let v = ((bh as u128) << 64) | bl as u128;
            let a = u as i128;
            let b = v as i128;
            let checked = a
                .checked_add(b)
                .map(|x| x.to_string())
                .unwrap_or("_".to_owned());
            let checked_u = u
                .checked_add(v)
                .map(|x| x.to_string())
                .unwrap_or("_".to_owned());
            let da = std::time::Duration::new(ah, (al % 1000000000) as u32);
            let db = std::time::Duration::new(bh, (bl % 1000000000) as u32);
            let duration = da
                .checked_add(db)
                .map(|x| format!("{},{}", x.as_secs(), x.subsec_nanos()))
                .unwrap_or("_".to_owned());
            format!(
                "{},{},{},{},{},{},{}",
                a.wrapping_add(b),
                a.wrapping_mul(b),
                checked,
                u.wrapping_add(v),
                u.wrapping_mul(v),
                checked_u,
                duration
            )
        })
        .collect::<Vec<_>>()
        .join(";")
}

fn evaluate_graphs(seed: u32) -> String {
    use differential_dataflow::algorithms::graphs::{bfs::bfs, propagate::{propagate, propagate_at}, scc::{strongly_connected, strongly_connected_at}};
    use differential_dataflow::input::Input;
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(usize, u32, u32), isize>::new()));
        let (mut edges, mut roots, probes) = worker.dataflow::<u64, _, _>(|scope| {
            let (edges, graph) = scope.new_collection::<(u32, u32), isize>();
            let (roots, source) = scope.new_collection::<u32, isize>();
            let labels = source.clone().map(|x| (x, x));
            let streams = [
                bfs(graph.clone(), source),
                propagate(graph.clone(), labels.clone()),
                strongly_connected(graph.clone()),
                propagate_at(graph.clone(), labels, |x| 1u64 << (x * 15)),
                strongly_connected_at(graph, |x| 1u64 << (x * 15)),
            ];
            let probes: Vec<_> = streams.into_iter().enumerate().map(|(op, stream)| {
                let sink = observed.clone();
                stream.inspect(move |&((a, b), _, diff)| {
                    *sink.borrow_mut().entry((op, a, b)).or_default() += diff;
                }).probe().0
            }).collect();
            (edges, roots, probes)
        });
        let mut random = seed;
        let mut weights = [0isize; 25];
        let mut active = [false; 5];
        let mut results = Vec::new();
        for epoch in 0..12 {
            for _ in 0..3 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = ((random >> 8) % 25) as usize;
                let next = if weights[index] == 0 { (random % 2) as isize + 1 } else { 0 };
                edges.update(((index / 5) as u32, (index % 5) as u32), next - weights[index]);
                weights[index] = next;
            }
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let node = ((random >> 8) % 5) as usize;
            active[node] = !active[node];
            roots.update(node as u32, if active[node] { 1 } else { -1 });
            edges.advance_to(epoch + 1);
            roots.advance_to(epoch + 1);
            edges.flush();
            roots.flush();
            let mut steps = 0;
            while probes.iter().any(|p| p.less_than(edges.time())) {
                worker.step();
                steps += 1;
                assert!(steps < 100000, "graph convergence bound");
            }
            results.push(observed.borrow().iter().filter(|(_, d)| **d != 0)
                .map(|((op, a, b), d)| format!("{op},{a},{b},{d}")).collect::<Vec<_>>().join(";"));
        }
        edges.close();
        roots.close();
        while probes.iter().any(|p| !p.done()) { worker.step(); }
        results.join("/")
    })
}
