use std::{cell::RefCell, rc::Rc};
use timely::dataflow::operators::generic::builder_rc::OperatorBuilder;
pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let count = Rc::new(RefCell::new(0u32));
        let counter = count.clone();
        let finished = Rc::new(RefCell::new(false));
        let source_finished = finished.clone();
        let activator = worker.dataflow::<u64,_,_>(|scope| {
            let mut builder = OperatorBuilder::new("activated source".to_owned(),scope.clone());
            let activator = scope.activator_for(builder.operator_info().address);
            let (output, _stream) = builder.new_output::<Vec<()>>();
            builder.build(move |mut caps| {
                move |_frontiers| {
                    let _ = &output;
                    if *source_finished.borrow() {
                        caps.clear();
                    } else {
                        *counter.borrow_mut() += 1;
                    }
                }
            });
            activator
        });
        for _ in 0..64 { worker.step(); }
        let baseline = *count.borrow();
        let mut random = seed;
        let mut output = Vec::new();
        for _ in 0..64 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            for _ in 0..((random >> 8) % 7) {
                if random % 2 == 0 { activator.activate(); }
                else { activator.activate_after(std::time::Duration::ZERO); }
            }
            for _ in 0..64 { worker.step(); }
            output.push((*count.borrow()-baseline).to_string());
        }
        let result = output.join(",");
        *finished.borrow_mut() = true;
        activator.activate();
        for _ in 0..64 { worker.step(); }
        result
    })
}
