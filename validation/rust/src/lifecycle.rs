use std::{cell::RefCell, rc::Rc};
use timely::dataflow::operators::generic::builder_rc::OperatorBuilder;
struct Close(Rc<RefCell<u32>>);
impl Drop for Close {
    fn drop(&mut self) { *self.0.borrow_mut() += 1; }
}
pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let calls = Rc::new(RefCell::new(0u32));
        let closed = Rc::new(RefCell::new(0u32));
        let finished = Rc::new(RefCell::new(false));
        let held = Rc::new(RefCell::new(Vec::new()));
        let activator = worker.dataflow::<u64,_,_>(|scope| {
            let mut builder = OperatorBuilder::new("resource lifetime".to_owned(), scope.clone());
            let activator = scope.activator_for(builder.operator_info().address);
            let (output, _stream) = builder.new_output::<Vec<()>>();
            let calls = calls.clone();
            let finished = finished.clone();
            let held = held.clone();
            let close = Close(closed.clone());
            builder.build_reschedule(move |caps| {
                *held.borrow_mut() = caps;
                move |_frontiers| {
                    let _ = (&close, &output);
                    *calls.borrow_mut() += 1;
                    !*finished.borrow()
                }
            });
            activator
        });
        for _ in 0..64 { worker.step(); }
        let mut previous = *calls.borrow();
        let mut records = Vec::new();
        for round in 0..48 {
            if round == seed % 24 { held.borrow_mut().clear(); }
            if round == (seed / 3) % 24 { *finished.borrow_mut() = true; }
            activator.activate();
            for _ in 0..64 { worker.step(); }
            // Scheduling may include redundant progress wakeups. The contract is
            // activity before shutdown and no invocations after resource release.
            let current = *calls.borrow();
            records.push(format!("{},{}", u32::from(current > previous), *closed.borrow()));
            previous = current;
        }
        records.join(";")
    })
}
