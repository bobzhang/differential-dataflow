use differential_dataflow::input::Input;
use timely::dataflow::operators::probe::Handle;
pub fn evaluate(seed:u32)->String {
    timely::execute_directly(move |worker| {
        let shared=Handle::new();
        let (mut a,mut b,pa,pb)=worker.dataflow::<u64,_,_>(|scope| {
            let (a,left)=scope.new_collection::<i32,i64>();
            let (b,right)=scope.new_collection::<i32,i64>();
            let (pa,_)=left.probe_with(&shared).probe();
            let (pb,_)=right.probe_with(&shared).probe();
            (a,b,pa,pb)
        });
        let mut state=seed;let mut ta=0;let mut tb=0;let mut rows=Vec::new();
        let snapshot=||shared.with_frontier(|f|f.iter().map(|t|t.to_string()).collect::<Vec<_>>().join(","));
        for _ in 0..12 {
            state=state.wrapping_mul(1664525).wrapping_add(1013904223);
            a.update(1,1);b.update(2,-1);
            ta+=((state>>8)%3+1) as u64;tb+=((state>>16)%3+1) as u64;
            a.advance_to(ta);a.flush();b.advance_to(tb);b.flush();
            while pa.less_than(&ta)||pb.less_than(&tb) {worker.step();}
            rows.push(snapshot());
        }
        a.close();while !pa.done(){worker.step();}rows.push(snapshot());
        b.close();while !pb.done(){worker.step();}assert!(shared.done());rows.push(snapshot());
        rows.join("/")
    })
}
