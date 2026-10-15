use std::{cell::RefCell, collections::{BTreeMap, VecDeque}, rc::Rc, time::Duration};
use differential_dataflow::{capture::{self, Message, Writer}, input::Input, Collection};
type Msg = Message<u32,u64,i64>;
struct Sink { messages: Vec<Msg>, retry: bool, attempts: usize }
impl Writer<Msg> for Sink {
    fn poll(&mut self, item: &Msg) -> Option<Duration> {
        if matches!(item, Message::Updates(_)) {
            self.attempts += 1;
            self.retry = !self.retry;
            if self.retry { return Some(Duration::ZERO); }
        }
        self.messages.push(item.clone());
        None
    }
    fn done(&self) -> bool { true }
}
pub fn evaluate(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let sink = Rc::new(RefCell::new(Sink { messages: vec![], retry: false, attempts: 0 }));
        let inbox = Rc::new(RefCell::new(VecDeque::<Msg>::new()));
        let observed = Rc::new(RefCell::new(BTreeMap::<u32,i64>::new()));
        let mut wake = None;
        let (mut input, token, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (input, source) = scope.new_collection::<u32,i64>();
            capture::sink::build(source.consolidate().inner, 0, Rc::downgrade(&sink), Rc::downgrade(&sink));
            let queue = inbox.clone();
            let (token, replay) = capture::source::build(scope, |activator| {
                wake = Some(activator);
                std::iter::from_fn(move || queue.borrow_mut().pop_front())
            });
            let seen = observed.clone();
            let (probe, _) = Collection::new(replay).inspect(move |&(d,_,r)| {
                *seen.borrow_mut().entry(d).or_default() += r;
            }).probe();
            (input, token, probe)
        });
        let mut random = seed;
        let mut output = vec![];
        for epoch in 0..24 {
            for _ in 0..12 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                input.update((random >> 8) % 16, (random % 5) as i64 - 2);
            }
            input.advance_to(epoch+1);
            input.flush();
            for _ in 0..512 { worker.step(); }
            // Deliver progress ahead of updates, including duplicate messages.
            let messages = std::mem::take(&mut sink.borrow_mut().messages);
            for message in messages.into_iter().rev() {
                inbox.borrow_mut().push_back(message.clone());
                inbox.borrow_mut().push_back(message);
            }
            wake.as_ref().unwrap().activate().unwrap();
            for _ in 0..512 { worker.step(); }
            assert!(!probe.less_than(&(epoch+1)));
            output.push(observed.borrow().iter().filter(|(_,r)| **r != 0)
                .map(|(d,r)| format!("{d},{r}")).collect::<Vec<_>>().join(";"));
        }
        drop(input);
        for _ in 0..512 { worker.step(); }
        inbox.borrow_mut().extend(std::mem::take(&mut sink.borrow_mut().messages));
        wake.unwrap().activate().unwrap();
        for _ in 0..512 { worker.step(); }
        assert!(probe.done());
        assert!(sink.borrow().attempts > 24);
        drop(token);
        for _ in 0..64 { worker.step(); }
        output.join("/")
    })
}

pub fn eager(seed: u32) -> String {
    timely::execute_directly(move |worker| {
        let queue = Rc::new(RefCell::new(VecDeque::<Msg>::new()));
        let input = queue.clone();
        let seen = Rc::new(RefCell::new(0usize));
        let count = seen.clone();
        let mut wake = None;
        let (token, probe) = worker.dataflow::<u64,_,_>(|scope| {
            let (token, stream) = capture::source::build(scope, |activator| {
                wake = Some(activator);
                std::iter::from_fn(move || input.borrow_mut().pop_front())
            });
            let (probe, _) = Collection::new(stream).inspect(move |_| *count.borrow_mut() += 1).probe();
            (token, probe)
        });
        let row = (seed, 0, (seed % 7 + 1) as i64);
        queue.borrow_mut().push_back(Message::Updates(vec![row,row]));
        let mut output = vec![];
        for phase in 0..3 {
            if phase == 1 { queue.borrow_mut().push_back(Message::Progress(capture::Progress { lower: vec![0], upper: vec![1], counts: vec![(0,1)] })); }
            if phase == 2 { queue.borrow_mut().push_back(Message::Progress(capture::Progress { lower: vec![1], upper: vec![], counts: vec![] })); }
            wake.as_ref().unwrap().activate().unwrap();
            for _ in 0..256 { worker.step(); }
            output.push(format!("{},{},{}",*seen.borrow(),probe.less_than(&1),probe.done()));
        }
        drop(token);
        output.join("/")
    })
}
