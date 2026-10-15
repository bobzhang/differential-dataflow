use differential_dataflow::{algorithms::graphs::{bijkstra::bidijkstra, sequential::sequence}, input::Input};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let observed = Rc::new(RefCell::new(BTreeMap::<(u32, u32, u32, i64), isize>::new()));
        let (mut edges, mut goals, mut input, p0, p1) = worker.dataflow::<u64, _, _>(|scope| {
            let (edges, graph) = scope.new_collection::<(u32, u32), isize>();
            let (goals, queries) = scope.new_collection::<(u32, u32), isize>();
            let (input, states) = scope.new_collection::<(u32, i32), isize>();
            let sink = observed.clone();
            let p0 = bidijkstra(graph.clone(), queries).inspect(move |&((pair, distance), _, diff)| {
                *sink.borrow_mut().entry((0, pair.0, pair.1, distance as i64)).or_default() += diff;
            }).probe().0;
            let sink = observed.clone();
            let p1 = sequence(states, graph, |_, values| {
                1 + values.iter().map(|(v, d)| **v * *d as i32).sum::<i32>()
            }).inspect(move |&((node, value), _, diff)| {
                *sink.borrow_mut().entry((1, node, 0, value.unwrap_or(-1) as i64)).or_default() += diff;
            }).probe().0;
            (edges, goals, input, p0, p1)
        });
        let mut weights = [0isize; 25];
        let mut requests = [0isize; 25];
        let mut values = [1i32, 2, 3, 4, 5];
        for i in 0..5 { input.insert((i as u32, values[i])); }
        let mut random = seed;
        let mut output = Vec::new();
        for epoch in 0..12 {
            for _ in 0..3 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = ((random >> 8) % 25) as usize;
                let next = if weights[index] == 0 { (random % 2) as isize + 1 } else { 0 };
                edges.update(((index / 5) as u32, (index % 5) as u32), next - weights[index]); weights[index] = next;
            }
            for _ in 0..2 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = ((random >> 8) % 25) as usize;
                let next = if requests[index] == 0 { (random % 2) as isize + 1 } else { 0 };
                goals.update(((index / 5) as u32, (index % 5) as u32), next - requests[index]); requests[index] = next;
            }
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let node = ((random >> 8) % 5) as usize;
            input.remove((node as u32, values[node])); values[node] = (random % 9) as i32 + 1; input.insert((node as u32, values[node]));
            edges.advance_to(epoch + 1); goals.advance_to(epoch + 1); input.advance_to(epoch + 1);
            edges.flush(); goals.flush(); input.flush();
            let mut steps = 0;
            while p0.less_than(input.time()) || p1.less_than(input.time()) { worker.step(); steps += 1; assert!(steps < 100000); }
            output.push(observed.borrow().iter().filter(|(_, d)| **d != 0).map(|((op, a, b, v), d)| format!("{op},{a},{b},{v},{d}")).collect::<Vec<_>>().join(";"));
        }
        edges.close(); goals.close(); input.close();
        while !p0.done() || !p1.done() { worker.step(); }
        "GRAPH_SEARCH|".to_owned() + &output.join("/")
    })
}
