use differential_dataflow::{dynamic::{feedback_summary, pointstamp::{PointStamp, PointStampSummary}}, lattice::Lattice, input::Input, operators::iterate::Variable};
use timely::{PartialOrder, progress::PathSummary, order::Product};
use std::{cell::RefCell,collections::BTreeMap,rc::Rc};
fn next(state: &mut u32) -> u32 { *state=state.wrapping_mul(1664525).wrapping_add(1013904223); *state }
fn vector(state: &mut u32) -> Vec<u64> { (0..next(state)%5).map(|_| u64::from((next(state)>>8)%7)).collect() }
fn show(v: &[u64]) -> String { format!("[{}]",v.iter().map(ToString::to_string).collect::<Vec<_>>().join(",")) }
fn result(v: Option<PointStamp<u64>>) -> String { v.map(|p| show(&p)).unwrap_or("N".into()) }
fn summary(s: Option<PointStampSummary<u64>>) -> String { s.map(|s| format!("{}:{}",s.retain.map(|n|n.to_string()).unwrap_or("n".into()),show(&s.actions))).unwrap_or("N".into()) }
pub fn evaluate(seed:u32)->String {
    let mut state=seed;
    let mut rows=Vec::new();
    for case in 0..32 {
        let a=PointStamp::new(vector(&mut state).into());
        let b=PointStamp::new(vector(&mut state).into());
        let retain=next(&mut state)%6;
        let mut actions=vector(&mut state);
        if case%8==0 { actions.push(u64::MAX); }
        let s=PointStampSummary{retain:if retain==0{None}else{Some((retain-1)as usize)},actions};
        let retain=next(&mut state)%6;
        let t=PointStampSummary{retain:if retain==0{None}else{Some((retain-1)as usize)},actions:vector(&mut state)};
        let order=match a.cmp(&b) {std::cmp::Ordering::Less=>-1,std::cmp::Ordering::Equal=>0,std::cmp::Ordering::Greater=>1};
        rows.push(format!("{}|{}|{}|{}|{}|{}|{}|{}",show(&a),show(&b),a.less_equal(&b),order,show(&a.join(&b)),show(&a.meet(&b)),result(s.results_in(&a)),summary(<PointStampSummary<u64> as PathSummary<PointStamp<u64>>>::followed_by(&s,&t))));
    }
    rows.join("/")
}
pub fn iterate(seed:u32)->String {
    timely::execute_directly(move |worker| {
        let observed=Rc::new(RefCell::new(BTreeMap::<u32,isize>::new()));
        let sink=observed.clone();
        let level=(seed%4+1)as usize;
        let (mut input,probe)=worker.dataflow::<u64,_,_>(|outer| {
            let (input,source)=outer.new_collection::<u32,isize>();
            let result=outer.iterative::<PointStamp<u64>,_,_>(|inner| {
                let source=source.enter(inner).enter_dynamic(level);
                let (variable,ranks)=Variable::new_from(source,Product::new(0,feedback_summary::<u64>(level,1)));
                let result=ranks.flat_map(|d| if d<11 {vec![d,d+1]}else{vec![d]}).distinct();
                variable.set(result.clone());
                result.leave_dynamic(level).leave(outer)
            });
            let (probe,_)=result.inspect(move |&(d,_,r)| *sink.borrow_mut().entry(d).or_default()+=r).probe();
            (input,probe)
        });
        let mut state=seed;
        let mut roots=std::collections::BTreeSet::new();
        let mut rows=Vec::new();
        for epoch in 0..8 {
            for _ in 0..3 {
                let d=(next(&mut state)>>8)%12;
                if roots.remove(&d) {input.remove(d);}else{roots.insert(d);input.insert(d);}
            }
            input.advance_to(epoch+1);input.flush();
            while probe.less_than(input.time()){worker.step();}
            rows.push(observed.borrow().iter().filter(|(_,r)|**r!=0).map(|(d,r)|format!("{d},{r}")).collect::<Vec<_>>().join(";"));
        }
        input.close();while !probe.done(){worker.step();}
        rows.join("/")
    })
}
