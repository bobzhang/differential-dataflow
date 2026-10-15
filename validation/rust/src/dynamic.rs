use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
use differential_dataflow::input::Input;
pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let (mut input, mut trace, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (input, values) = scope.new_collection::<(u32,u32),i64>();
            let arranged = values.arrange_by_key();
            let trace = arranged.trace.clone();
            let (probe, _) = arranged.as_collection(|k,v| (*k,*v)).probe();
            (input,trace,probe)
        });
        let mut random = seed;
        let mut queries = Vec::new();
        let mut results = Vec::new();
        for epoch in 0u64..16 {
            for _ in 0..6 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = (random >> 8) % 16;
                input.update((index/4,index%4), (random%5) as i64-2);
            }
            input.advance_to(epoch+1);
            input.flush();
            while probe.less_than(input.time()) { worker.step(); }
            let observed = Rc::new(RefCell::new(BTreeMap::<(u32,u32),i64>::new()));
            let shared = observed.clone();
            let imported = worker.dataflow::<u64,_,_>(|scope| {
                let (probe, _) = trace.import(scope).as_collection(move |k,v| (*k,*v+epoch as u32))
                    .consolidate().inspect(move |(d,_,r)| *shared.borrow_mut().entry(*d).or_default() += r).probe();
                probe
            });
            queries.push((observed, imported));
            for (_, imported) in &queries { while imported.less_than(input.time()) { worker.step(); } }
            results.push(queries.iter().map(|(observed,_)| {
                observed.borrow().iter().filter(|(_,r)| **r != 0).map(|((k,v),r)| format!("{},{},{}",k,v,r)).collect::<Vec<_>>().join(";")
            }).collect::<Vec<_>>().join("|"));
        }
        input.close();
        while !probe.done() { worker.step(); }
        for (_, imported) in &queries { while !imported.done() { worker.step(); } }
        results.join("/")
    })
}
