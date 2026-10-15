use differential_dataflow::{AsCollection, difference::Present, trace::implementations::{ValBuilder, ValSpine}};
use timely::order::Product;
use timely::dataflow::operators::ToStream;
use std::{cell::RefCell, rc::Rc, collections::BTreeSet};
pub fn evaluate(seed:u32)->String {
    timely::execute_directly(move |worker| {
        let observed=Rc::new(RefCell::new(Vec::new()));
        let sink=observed.clone();
        let mut random=seed;
        let updates=(0..48).map(|_| {
            random=random.wrapping_mul(1664525).wrapping_add(1013904223);
            let i=(random>>8)%375;
            ((i/125,i%5),Product::new((i/25%5) as u64,(i/5%5) as u64),(random%3+1) as i64)
        }).collect::<Vec<_>>();
        let probe=worker.dataflow::<u64,_,_>(|outer| {
            outer.scoped::<Product<u64,u64>,_,_>("CorePresence",|scope| {
                let (probe,_) = updates.to_stream(scope).as_collection()
                    .reduce_core::<_,ValBuilder<u32,u32,Product<u64,u64>,Present>,ValSpine<u32,u32,Product<u64,u64>,Present>>(
                        "CorePresence",|_,values,previous,changes| {
                            for (v,_) in values {
                                if !previous.iter().any(|(old,_)|old==*v) { changes.push((**v,Present)); }
                            }
                        }).as_collection(|k,v|(*k,*v))
                    .inspect(move |&(d,t,_)|sink.borrow_mut().push((d,t))).probe();
                probe
            })
        });
        while !probe.done() { worker.step(); }
        let mut rows=Vec::new();
        for x in 0..5 { for y in 0..5 {
            let present=observed.borrow().iter().filter(|(_,t)|t.outer<=x&&t.inner<=y).map(|(d,_)|*d).collect::<BTreeSet<_>>();
            rows.push(present.iter().map(|(k,v)|format!("{k},{v}")).collect::<Vec<_>>().join(";"));
        }}
        rows.join("/")
    })
}
