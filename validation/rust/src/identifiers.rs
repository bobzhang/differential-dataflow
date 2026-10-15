use differential_dataflow::operators::Iterate;
use differential_dataflow::{Hashable, algorithms::identifiers::Identifiers, input::Input};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

pub fn evaluate(seed: u32) -> String {
    let result = timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(usize, i32, u64), i64>::new()));
        let (mut input, probes) = worker.dataflow::<u64, _, _>(|scope| {
            let (input, source) = scope.new_collection::<i32, i64>();
            let initial = source.clone().map(|data| (0i32, data));
            let changes = initial.clone().filter(|_| false).iterate(|inner, changes| {
                initial.clone().enter(inner).concat(changes)
                    .map(|pair| (((pair.0 + pair.1) / 8) as u64, pair))
                    .reduce(|_, values, output| {
                        let ((round, data), count) = values[0];
                        if *round > 0 { output.push(((0, *data), -count)); output.push(((*round, *data), count)); }
                        for ((round, data), count) in values[1..].iter() {
                            output.push(((0, *data), -*count)); output.push(((*round + 1, *data), *count));
                        }
                    }).map(|(_, pair)| pair)
            });
            let custom = changes.concat(initial).map(|(round, data)| (data, ((round + data) / 8) as u64));
            let streams = [source.identifiers(), custom];
            let probes: Vec<_> = streams.into_iter().enumerate().map(|(op, stream)| {
                let sink = observed.clone();
                stream.inspect(move |&((data, id), _, diff)| {
                    *sink.borrow_mut().entry((op, data, id)).or_default() += diff;
                }).probe().0
            }).collect();
            (input, probes)
        });
        let mut random = seed;
        let mut weights = [0i64; 12];
        let mut output = Vec::new();
        for epoch in 0..12 {
            for _ in 0..3 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = ((random >> 8) % 12) as usize;
                let next = if weights[index] == 0 { (random % 3) as i64 + 1 } else { 0 };
                input.update(index as i32, next - weights[index]); weights[index] = next;
            }
            input.advance_to(epoch + 1); input.flush();
            let mut steps = 0;
            while probes.iter().any(|p| p.less_than(input.time())) { worker.step(); steps += 1; assert!(steps < 100000); }
            output.push(observed.borrow().iter().filter(|(_, d)| **d != 0).map(|((op, data, id), diff)| format!("{op},{data},{id},{diff}")).collect::<Vec<_>>().join(";"));
        }
        input.close();
        while probes.iter().any(|p| !p.done()) { worker.step(); }
        output.join("/")
    });
    let hashes = [
        (-12i8).hashed(), (-123i16).hashed(), (-456i32).hashed(),
        0xfedcba9876543210u64.hashed(), 0x123456789abcdef0fedcba9876543210u128.hashed(),
        "🌙\0Moon".hashed(), b"\x00\xff".as_slice().hashed(), vec![1i32, -2, 3].hashed(),
        Some(42i32).hashed(), None::<i32>.hashed(), ('🌙', true, ()).hashed(),
    ];
    result + "#" + &hashes.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
}
