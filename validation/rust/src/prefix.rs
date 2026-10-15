use differential_dataflow::{algorithms::prefix_sum::PrefixSum, input::Input};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let results = Rc::new(RefCell::new(BTreeMap::<(usize, usize, usize, i64), isize>::new()));
        let (mut input, mut queries, probes) = worker.dataflow::<u64, _, _>(|scope| {
            let (input, source) = scope.new_collection::<((usize, usize), i64), isize>();
            let (queries, locations) = scope.new_collection::<(usize, usize), isize>();
            let streams = [source.clone().prefix_sum_at(locations, 0, |_, a, b| a + b), source.prefix_sum(0, |_, a, b| a + b)];
            let probes: Vec<_> = streams.into_iter().enumerate().map(|(op, stream)| {
                let sink = results.clone();
                stream.inspect(move |&(((position, key), value), _, diff)| {
                    *sink.borrow_mut().entry((op, position, key, value)).or_default() += diff;
                }).probe().0
            }).collect();
            (input, queries, probes)
        });
        let positions = [0, 1, 3, 7, 10, 31, 1usize << 32, 1usize << 63];
        let targets = [0, 1, 2, 4, 8, 32, 1usize << 63, usize::MAX];
        let mut values = [0i64; 16];
        let mut requests = [0isize; 16];
        let mut random = seed;
        let mut output = Vec::new();
        for epoch in 0..12 {
            for _ in 0..3 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = ((random >> 8) % 16) as usize;
                let value = values[index];
                let key = (positions[index % 8], index / 8);
                if value != 0 { input.remove((key, value)); }
                values[index] = if value == 0 { (random % 9) as i64 + 1 } else { 0 };
                if values[index] != 0 { input.insert((key, values[index])); }
            }
            for _ in 0..3 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = ((random >> 8) % 16) as usize;
                let next = if requests[index] == 0 { (random % 2) as isize + 1 } else { 0 };
                queries.update((targets[index % 8], index / 8), next - requests[index]);
                requests[index] = next;
            }
            input.advance_to(epoch + 1);
            queries.advance_to(epoch + 1);
            input.flush(); queries.flush();
            let mut steps = 0;
            while probes.iter().any(|p| p.less_than(input.time())) {
                worker.step(); steps += 1;
                assert!(steps < 100000, "prefix convergence");
            }
            output.push(results.borrow().iter().filter(|(_, d)| **d != 0).map(|((op, p, k, v), d)| format!("{op},{p},{k},{v},{d}")).collect::<Vec<_>>().join(";"));
        }
        input.close(); queries.close();
        while probes.iter().any(|p| !p.done()) { worker.step(); }
        output.join("/")
    })
}
