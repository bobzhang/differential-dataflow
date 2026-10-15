use std::io::{self, BufRead};
use timely::order::Product;
use timely::progress::{Antichain, frontier::MutableAntichain};
use differential_dataflow::lattice::Lattice;
fn evaluate(seed: u32) -> String {
    let mut random = seed;
    let mut frontier = MutableAntichain::<Product<i64,i64>>::new();
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
        let mut minimal = frontier.frontier().to_vec(); minimal.sort();
        let antichain: Antichain<_> = minimal.iter().cloned().collect();
        let mut time = Product::new((seed % 5) as i64, ((seed / 5) % 5) as i64);
        time.advance_by(antichain.borrow());
        result.push(format!("{}|{}|{},{}",
            changes.iter().map(|(t,d)| format!("{},{},{}",t.outer,t.inner,d)).collect::<Vec<_>>().join(";"),
            minimal.iter().map(|t| format!("{},{}",t.outer,t.inner)).collect::<Vec<_>>().join(";"),
            time.outer,time.inner));
    }
    result.join("/")
}
fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    for line in io::stdin().lock().lines() { let seed = line.unwrap().parse().unwrap(); println!("{}", match mode.as_str() { "join" => evaluate_join(seed), "reduce" => evaluate_reduce(seed), "feedback" => evaluate_feedback(seed), "iteration" => evaluate_iteration(seed), "arrangement" => evaluate_arrangement(seed), "upsert" => evaluate_upsert(seed), _ => evaluate(seed) }); }
}
fn evaluate_join(seed: u32) -> String {
    use differential_dataflow::input::Input;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::rc::Rc;
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32,u32,u32),i64>::new()));
        let sink = observed.clone();
        let (mut a, mut b, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (a,left) = scope.new_collection::<(u32,u32),i64>();
            let (b,right) = scope.new_collection::<(u32,u32),i64>();
            let (probe,_) = left.join(right).consolidate().inspect(move |&((k,(v,w)),_,diff)| {
                *sink.borrow_mut().entry((k,v,w)).or_default() += diff;
            }).probe();
            (a,b,probe)
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
                    if side == 0 { a.update(data,diff); } else { b.update(data,diff); }
                }
            }
            a.advance_to(epoch+1); b.advance_to(epoch+1); a.flush(); b.flush();
            while probe.less_than(a.time()) { worker.step(); }
            results.push(observed.borrow().iter().filter(|(_,d)| **d != 0).map(|(&(k,v,w),d)| format!("{k},{v},{w},{d}")).collect::<Vec<_>>().join(";"));
        }
        a.close(); b.close();
        while !probe.done() { worker.step(); }
        results.join("/")
    })
}

fn evaluate_reduce(seed: u32) -> String {
    use differential_dataflow::AsCollection;
    use timely::dataflow::operators::ToStream;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::rc::Rc;
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32,u32,i64,u64,u64),i64>::new()));
        let sinks = [observed.clone(), observed.clone(), observed.clone()];
        let mut random = seed;
        let mut updates = Vec::new();
        for _ in 0..32 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = (random >> 8) % 375;
            updates.push(((index / 125, index % 5),Product::new((index / 25 % 5) as u64,(index / 5 % 5) as u64),(random % 5) as i64 - 2));
        }
        let probes = worker.dataflow::<u64,_,_>(|outer| outer.scoped::<Product<u64,u64>,_,_>("ReduceCheck", |scope| {
            let collection = updates.to_stream(scope).as_collection();
            let [s0,s1,s2] = sinks;
            let (p0,_) = collection.clone().map(|(k,_)| k).distinct_core::<i64>().inspect(move |&(k,t,d)| {
                *s0.borrow_mut().entry((0,k,0,t.outer,t.inner)).or_default() += d;
            }).probe();
            let (p1,_) = collection.clone().map(|(k,_)| k).count().inspect(move |&((k,v),t,d)| {
                *s1.borrow_mut().entry((1,k,v,t.outer,t.inner)).or_default() += d as i64;
            }).probe();
            let (p2,_) = collection.reduce(|_k,values,output| output.push((*values[0].0,1i64))).inspect(move |&((k,v),t,d)| {
                *s2.borrow_mut().entry((2,k,v as i64,t.outer,t.inner)).or_default() += d;
            }).probe();
            [p0,p1,p2]
        }));
        while probes.iter().any(|p| !p.done()) { worker.step(); }
        let result = observed.borrow().iter().filter(|(_,d)| **d != 0).map(|(&(op,k,v,x,y),d)| format!("{op},{k},{v},{x},{y},{d}")).collect::<Vec<_>>().join(";");
        result
    })
}

fn evaluate_feedback(seed: u32) -> String {
    use differential_dataflow::{input::Input, operators::iterate::VecVariable};
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32,u64),i64>::new()));
        let sink = observed.clone();
        let delay = (seed % 3 + 1) as u64;
        let (mut input, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (input, values) = scope.new_collection::<u32,i64>();
            let (feedback, looped) = VecVariable::new(scope, delay);
            let all = values.concat(looped);
            feedback.set(all.clone().map(|x| x+1).filter(|x| *x<12).consolidate());
            let (probe,_) = all.consolidate().inspect(move |&(d,t,r)| {
                *sink.borrow_mut().entry((d,t)).or_default() += r;
            }).probe();
            (input, probe)
        });
        let mut random = seed;
        let mut result = Vec::new();
        for epoch in 0..4 {
            for _ in 0..8 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                input.update((random >> 8) % 8, (random % 5) as i64 - 2);
            }
            input.advance_to((epoch+1)*64); input.flush();
            while probe.less_than(input.time()) { worker.step(); }
            result.push(observed.borrow().iter().filter(|(_,r)| **r!=0).map(|(&(d,t),r)| format!("{d},{t},{r}")).collect::<Vec<_>>().join(";"));
        }
        input.close();
        while !probe.done() { worker.step(); }
        result.join("/")
    })
}

fn evaluate_iteration(seed: u32) -> String {
    use differential_dataflow::{input::Input, operators::Iterate};
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    timely::execute_directly(move |worker| {
        let mut random=seed;
        let mut edges=vec![Vec::new();6];
        for _ in 0..12 {
            random=random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index=(random>>8)%36;
            edges[(index/6) as usize].push(index%6);
        }
        let observed=Rc::new(RefCell::new(BTreeMap::<u32,i64>::new()));
        let sink=observed.clone();
        let (mut input,probe)=worker.dataflow::<u64,_,_>(|scope| {
            let (input,source)=scope.new_collection::<u32,i64>();
            let result=source.iterate(move |_,values| {
                values.clone().concat(values.flat_map(move |x| edges[x as usize].clone())).distinct_core::<i64>()
            });
            let (probe,_)=result.consolidate().inspect(move |&(d,_,r)| { *sink.borrow_mut().entry(d).or_default()+=r; }).probe();
            (input,probe)
        });
        let mut roots=[false;6];
        let mut result=Vec::new();
        for epoch in 0..8 {
            for _ in 0..2 {
                random=random.wrapping_mul(1664525).wrapping_add(1013904223);
                let key=((random>>8)%6) as usize;
                roots[key]=!roots[key];
                input.update(key as u32,if roots[key] {1} else {-1});
            }
            input.advance_to(epoch+1); input.flush();
            while probe.less_than(input.time()) { worker.step(); }
            result.push(observed.borrow().iter().filter(|(_,r)| **r!=0).map(|(d,r)| format!("{d},{r}")).collect::<Vec<_>>().join(";"));
        }
        input.close(); while !probe.done() { worker.step(); }
        result.join("/")
    })
}

fn evaluate_arrangement(seed: u32) -> String {
    use differential_dataflow::{input::Input, trace::{TraceReader, Cursor}};
    timely::execute_directly(move |worker| {
        let (mut input, mut trace, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (input, values) = scope.new_collection::<(u32,u32),i64>();
            let arranged = values.arrange_by_key();
            let trace = arranged.trace.clone();
            let (probe,_) = arranged.as_collection(|k,v| (*k,*v)).probe();
            (input,trace,probe)
        });
        let mut slow=trace.clone();
        let mut random=seed;
        let mut result=Vec::new();
        for epoch in 0..16 {
            for _ in 0..6 {
                random=random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index=(random>>8)%12;
                input.update((index/4,index%4),(random%5) as i64-2);
            }
            input.advance_to(epoch+1); input.flush();
            while probe.less_than(input.time()) { worker.step(); }
            let past=epoch/4*4;
            trace.set_logical_compaction(Antichain::from_elem(epoch).borrow());
            trace.set_physical_compaction(Antichain::from_elem(epoch+1).borrow());
            slow.set_logical_compaction(Antichain::from_elem(past).borrow());
            slow.set_physical_compaction(Antichain::from_elem(past).borrow());
            let mut snapshots=Vec::new();
            for query in [past,epoch] {
                let (mut cursor, storage)=slow.cursor();
                let mut records=Vec::new();
                while cursor.key_valid(&storage) {
                    while cursor.val_valid(&storage) {
                        let mut count=0i64;
                        cursor.map_times(&storage,|t,r| if *t<=query {count+=*r});
                        if count!=0 { records.push(format!("{},{},{}",cursor.key(&storage),cursor.val(&storage),count)); }
                        cursor.step_val(&storage);
                    }
                    cursor.step_key(&storage);
                }
                snapshots.push(records.join(";"));
            }
            result.push(snapshots.join("|"));
        }
        input.close(); while !probe.done() {worker.step();}
        result.join("/")
    })
}

fn evaluate_upsert(seed: u32) -> String {
    use differential_dataflow::{operators::arrange::upsert::arrange_from_upsert, trace::implementations::{ValBuilder, ValSpine}};
    use timely::dataflow::operators::ToStream;
    use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
    timely::execute_directly(move |worker| {
        let mut random=seed;
        let mut updates=Vec::new();
        for _ in 0..64 {
            random=random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index=(random>>8)%256;
            updates.push((index/64,if random%4==0 {None} else {Some(index%8)},(index/8%8) as u64));
        }
        let observed=Rc::new(RefCell::new(BTreeMap::<(u32,u32,u64),i64>::new()));
        let sink=observed.clone();
        let probe=worker.dataflow::<u64,_,_>(|scope| {
            let arranged=arrange_from_upsert::<ValBuilder<u32,u32,u64,isize>,ValSpine<u32,u32,u64,isize>,u32,u32>(updates.to_stream(scope),"UpsertCheck");
            let (probe,_)=arranged.as_collection(|k,v| (*k,*v)).inspect(move |&((k,v),t,r)| { *sink.borrow_mut().entry((k,v,t)).or_default()+=r as i64; }).probe();
            probe
        });
        while !probe.done() { worker.step(); }
        let result=observed.borrow().iter().filter(|(_,r)| **r!=0).map(|(&(k,v,t),r)| format!("{k},{v},{t},{r}")).collect::<Vec<_>>().join(";");
        result
    })
}
