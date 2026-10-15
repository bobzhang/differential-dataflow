use std::{cell::RefCell, rc::Rc};
use differential_dataflow::input::Input;
pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let sum = Rc::new(RefCell::new(0i64));
        let sink = sum.clone();
        let (mut sibling, live) = worker.dataflow::<u64,_,_>(|scope| {
            let (input, values) = scope.new_collection::<i64,i64>();
            let (probe, _) = values.inspect(move |&(d,_,r)| *sink.borrow_mut() += d*r).probe();
            (input,probe)
        });
        let mut results = Vec::new();
        let mut random = seed;
        for epoch in 0..16 {
            let id = worker.next_dataflow_index();
            let observed = Rc::new(RefCell::new(0i64));
            let sink = observed.clone();
            let (mut input, probe) = worker.dataflow::<u64,_,_>(|scope| {
                let (input, values) = scope.new_collection::<i64,i64>();
                let values = scope.iterative::<u64,_,_>(|inner| values.enter(inner).map(|d| d*2).leave(scope));
                let (probe, _) = values.inspect(move |&(d,_,r)| *sink.borrow_mut() += d*r).probe();
                (input,probe)
            });
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let value = i64::from((random >> 8) % 100);
            input.update(value, 1);
            input.advance_to(1);
            input.flush();
            while probe.less_than(input.time()) { worker.step(); }
            input.update(999, 1);
            input.flush();
            worker.drop_dataflow(id);
            input.close();
            sibling.update(value, 1);
            sibling.advance_to(epoch+1);
            sibling.flush();
            while live.less_than(sibling.time()) { worker.step(); }
            results.push(format!("{},{},{},{}", observed.borrow(),sum.borrow(),probe.done(),worker.installed_dataflows().contains(&id)));
        }
        sibling.close();
        while !live.done() { worker.step(); }
        results.join("/")
    })
}
