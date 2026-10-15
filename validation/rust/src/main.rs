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
    let join = std::env::args().nth(1).as_deref() == Some("join");
    for line in io::stdin().lock().lines() { let seed = line.unwrap().parse().unwrap(); println!("{}", if join { evaluate_join(seed) } else { evaluate(seed) }); }
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
