use std::{cell::RefCell, collections::{BTreeMap, VecDeque}, rc::Rc, sync::{Arc, Barrier}};
use differential_dataflow::{capture::{self, Message, Progress}, Collection};
pub fn evaluate(seed: u32) -> String {
    let peers = 3;
    let barrier = Arc::new(Barrier::new(peers));
    let guards = timely::execute(timely::Config::process(peers), move |worker| {
        let inbox = Rc::new(RefCell::new(VecDeque::<Message<u32,u64,i64>>::new()));
        let observed = Rc::new(RefCell::new(BTreeMap::<u32,i64>::new()));
        let queue = inbox.clone();
        let seen = observed.clone();
        let mut wake = None;
        let (token, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (token, stream) = capture::source::build(scope, |activator| {
                wake = Some(activator);
                std::iter::from_fn(move || queue.borrow_mut().pop_front())
            });
            let (probe, _) = Collection::new(stream).inspect(move |&(d,_,r)| {
                *seen.borrow_mut().entry(d).or_default() += r;
            }).probe();
            (token,probe)
        });
        let mut random = seed;
        let mut result = vec![];
        for epoch in 0..16 {
            inbox.borrow_mut().push_back(Message::Progress(Progress { lower: vec![epoch], upper: vec![epoch+1], counts: vec![(epoch,8)] }));
            for slot in 0..8 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let data = (seed % 16 + slot) % 16;
                let diff = (random % 3 + 1) as i64 * if random % 2 == 0 { 1 } else { -1 };
                let owner = (slot as usize + epoch as usize) % peers;
                if worker.index() == owner || worker.index() == (owner+1) % peers {
                    for _ in 0..2 { inbox.borrow_mut().push_back(Message::Updates(vec![(data,epoch,diff)])); }
                }
            }
            wake.as_ref().unwrap().activate().unwrap();
            while probe.less_than(&(epoch+1)) { worker.step(); }
            result.push(observed.borrow().clone());
            barrier.wait();
        }
        if worker.index() == peers-1 {
            inbox.borrow_mut().push_back(Message::Progress(Progress { lower: vec![16], upper: vec![], counts: vec![] }));
            wake.as_ref().unwrap().activate().unwrap();
        }
        while !probe.done() { worker.step(); }
        drop(token);
        result
    }).unwrap();
    let mut totals = vec![BTreeMap::<u32,i64>::new();16];
    for worker in guards.join() {
        for (epoch, rows) in worker.unwrap().into_iter().enumerate() {
            for (d,r) in rows { *totals[epoch].entry(d).or_default() += r; }
        }
    }
    totals.iter().map(|rows| rows.iter().filter(|(_,r)| **r != 0)
        .map(|(d,r)| format!("{d},{r}")).collect::<Vec<_>>().join(";")).collect::<Vec<_>>().join("/")
}
