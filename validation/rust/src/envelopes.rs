use differential_dataflow::input::Input;
use std::{cell::RefCell, rc::Rc};
pub fn evaluate(seed:u32)->String {
    timely::execute_directly(move |worker| {
        let observed=Rc::new(RefCell::new(Vec::<(i32,i64,i32,i64,i64)>::new()));
        let (mut input,probes)=worker.dataflow::<i64,_,_>(|scope| {
            let (input,source)=scope.new_collection::<i32,i64>();
            let sinks=(0..6).map(|_|observed.clone()).collect::<Vec<_>>();
            let s=sinks[0].clone();
            let (p0,_)=source.clone().consolidate_stream().inspect_batch(move |&cap,rows| {
                for &(d,t,r) in rows {s.borrow_mut().push((0,cap,d,t,r));}
            }).probe();
            let s=sinks[1].clone();
            let (p1,_)=source.clone().results_in(-3).inspect_batch(move |&cap,rows| {
                for &(d,t,r) in rows {s.borrow_mut().push((1,cap,d,t,r));}
            }).probe();
            let s=sinks[2].clone();
            let (p2,_)=source.clone().results_in(3).delay(|t|t+2).inspect_batch(move |&cap,rows| {
                for &(d,t,r) in rows {s.borrow_mut().push((2,cap,d,t,r));}
            }).probe();
            let s=sinks[3].clone();
            let (p3,_)=source.clone().join_function(|d|vec![(d+1,(d%7)as i64*5,2i64),(d+1,(d%5)as i64*7,-1i64)])
                .inspect_batch(move |&cap,rows| {for &(d,t,r) in rows {s.borrow_mut().push((3,cap,d,t,r));}}).probe();
            let s=sinks[4].clone();
            let (p4,_)=scope.iterative::<u64,_,_>(|inner| source.clone().enter_at(inner,|&d|d as u64).leave(scope))
                .inspect_batch(move |&cap,rows| {for &(d,t,r) in rows {s.borrow_mut().push((4,cap,d,t,r));}}).probe();
            let s=sinks[5].clone();
            let (p5,_)=source.map(|d|d).inspect_batch(move |&cap,rows| {for &(d,t,r) in rows {s.borrow_mut().push((5,cap,d,t,r));}}).probe();
            (input,vec![p0,p1,p2,p3,p4,p5])
        });
        input.advance_to(0);input.flush();
        let mut state=seed;let mut results=Vec::new();
        let snapshot=|| {let mut rows=observed.borrow().clone();rows.sort();rows.iter().map(|(a,b,c,d,e)|format!("{a},{b},{c},{d},{e}")).collect::<Vec<_>>().join(";")};
        for epoch in 0..12i64 {
            for _ in 0..6 {
                state=state.wrapping_mul(1664525).wrapping_add(1013904223);
                let d=((state>>8)%8) as i32;
                input.update_at(d,epoch+10+(d%3) as i64,(state%5) as i64-2);
            }
            input.advance_to(epoch+1);input.flush();
            while probes.iter().any(|p|p.less_than(&(epoch+1))) {worker.step();}
            results.push(snapshot());
        }
        input.close();while probes.iter().any(|p|!p.done()) {worker.step();}
        results.push(snapshot());results.join("/")
    })
}
