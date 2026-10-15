//! Pinned upstream hello/degrees, pagerank, and itembased_cf algorithms.
use differential_dataflow::{input::Input, operators::iterate::Variable, AsCollection};
use std::{cell::RefCell, collections::{BTreeMap, BTreeSet}, rc::Rc};
use timely::{order::Product, dataflow::operators::vec::Filter};

pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let ranks = Rc::new(RefCell::new(BTreeMap::<u32, isize>::new()));
        let degrees = Rc::new(RefCell::new(BTreeMap::<(isize, isize), isize>::new()));
        let scores = Rc::new(RefCell::new(BTreeMap::<((u32, u32), (isize, isize)), isize>::new()));
        let (r, d, s) = (ranks.clone(), degrees.clone(), scores.clone());
        let (mut input, probes) = worker.dataflow::<u64, _, _>(|scope| {
            let (input, edges) = scope.new_collection::<(u32, u32), isize>();
            let (pd, _) = edges.clone().map(|e| e.0).count().map(|e| e.1).count()
                .inspect(move |&(data, _, diff)| *d.borrow_mut().entry(data).or_default() += diff).probe();
            let users = edges.clone().map(|e| e.0).count().filter(|e| e.1 < 4).map(|e| e.0);
            let remaining = edges.clone().semijoin(users);
            let counts = remaining.clone().map(|e| e.1).count();
            let cooc = remaining.clone().join(remaining).map(|(_, pair)| pair).filter(|p| p.0 > p.1).count();
            let score = cooc.map(|((a,b),n)| (a,(b,n))).join(counts.clone())
                .map(|(a,((b,n),c))| (b,(a,n,c))).join(counts)
                .map(|(b,((a,n,c),d))| ((a,b),(n,c+d-n))).filter(|row| row.1.0*20 > row.1.1);
            let (ps, _) = score.inspect(move |&(data, _, diff)| *s.borrow_mut().entry(data).or_default() += diff).probe();
            let nodes = edges.clone().flat_map(|(x,y)| [x,y]).distinct();
            let degrs = edges.clone().map(|e| e.0).count();
            let rank = scope.iterative::<u64, _, _>(|inner| {
                let edges = edges.enter(inner);
                let nodes = nodes.enter(inner);
                let degrs = degrs.enter(inner);
                let initial = nodes.clone().explode(|node| Some((node, 6_000_000isize)));
                let reset = nodes.explode(|node| Some((node, 1_000_000isize)));
                let (variable, ranks) = Variable::new_from(initial, Product::new(0,1));
                let push = degrs.semijoin(ranks).threshold(|(_,degree), rank| 5*rank/(6*degree)).map(|e| e.0);
                let pushed = edges.semijoin(push).map(|e| e.1).concat(reset).consolidate()
                    .inner.filter(move |(_,t,_)| t.inner < u64::from(seed % 5 + 1)).as_collection();
                variable.set(pushed.clone());
                pushed.leave(scope)
            });
            let (pr, _) = rank.inspect(move |&(data, _, diff)| *r.borrow_mut().entry(data).or_default() += diff).probe();
            (input, [pr,pd,ps])
        });
        let mut active = BTreeSet::new();
        let mut random = seed;
        let mut results = Vec::new();
        for epoch in 0..12 {
            if epoch == 11 {
                for &edge in &active { input.remove(edge); }
                active.clear();
            } else if epoch != 0 {
                for _ in 0..10 {
                    random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                    let index = (random >> 8) % 64;
                    let edge = (index/8,index%8);
                    if active.remove(&edge) { input.remove(edge); }
                    else { active.insert(edge); input.insert(edge); }
                }
            }
            input.advance_to(epoch+1);
            input.flush();
            while probes.iter().any(|p| p.less_than(input.time())) { worker.step(); }
            let rank = ranks.borrow().iter().filter(|(_,n)| **n != 0).map(|(k,n)| format!("{k},{n}")).collect::<Vec<_>>().join(";");
            let degree = degrees.borrow().iter().filter(|(_,n)| **n != 0).map(|((k,v),n)| format!("{k},{v},{n}")).collect::<Vec<_>>().join(";");
            let score = scores.borrow().iter().filter(|(_,n)| **n != 0).map(|(((a,b),(c,d)),n)| format!("{a},{b},{c},{d},{n}")).collect::<Vec<_>>().join(";");
            results.push(format!("{rank}|{degree}|{score}"));
        }
        input.close();
        while probes.iter().any(|p| !p.done()) { worker.step(); }
        results.join("/")
    })
}
