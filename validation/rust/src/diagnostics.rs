use std::{cell::RefCell,rc::Rc,time::{Duration,Instant}};
use differential_dataflow::{consolidation::consolidate_updates,logging::{DifferentialEvent,DifferentialEventBuilder},operators::arrange::TraceAgent,trace::{Builder,Description,Trace,TraceReader,implementations::{ValSpine,ValBuilder}}};
use timely::{dataflow::operators::generic::OperatorInfo,progress::Antichain};
pub fn evaluate(seed:u32)->String {
    let totals=Rc::new(RefCell::new((0i64,0i64,0i64)));
    let capture=totals.clone();
    let logger=timely::logging_core::Logger::<DifferentialEventBuilder>::new(Instant::now(),Duration::ZERO,move |_,batch| {
        if let Some(events)=batch { for (_,event) in events.drain(..) {
            let mut t=capture.borrow_mut();
            match event {
                DifferentialEvent::Batch(e)=>{t.0+=e.length as i64;t.2+=e.length as i64;},
                DifferentialEvent::Drop(e)=>t.2-=e.length as i64,
                DifferentialEvent::TraceShare(e)=>t.1+=e.diff as i64,
                DifferentialEvent::Merge(e)=>if let Some(n)=e.complete {t.2+=n as i64-e.length1 as i64-e.length2 as i64},
                _=>()
            }
            assert!(t.1>=0 && t.2>=0,"negative log balance: {:?}",*t);
        }}
    }).into_typed();
    let info=OperatorInfo::new(7,7,vec![7].into());
    let spine=ValSpine::<u32,u32,u64,i64>::new(info.clone(),Some(logger.clone()),None);
    let (mut reader,mut writer)=TraceAgent::new(spine,info,Some(logger.clone()));
    let mut pins=Vec::new();let mut state=seed;let mut rows=Vec::new();
    for epoch in 0..24u64 {
        let mut updates=Vec::new();
        for _ in 0..12 {
            state=state.wrapping_mul(1664525).wrapping_add(1013904223);
            let index=(state>>8)%36;
            updates.push(((index/6,index%6),epoch,(state%5) as i64-2));
        }
        if (state>>16)%3==0 {pins.push(reader.clone());}
        if state%5==0 && !pins.is_empty() {pins.remove(0);}
        consolidate_updates(&mut updates);
        let batch=ValBuilder::<u32,u32,u64,i64>::seal(&mut vec![updates],Description::new(Antichain::from_elem(epoch),Antichain::from_elem(epoch+1),Antichain::from_elem(0)));
        writer.insert(batch,None);
        let frontier=Antichain::from_elem(epoch.saturating_sub(2));
        reader.set_logical_compaction(frontier.borrow());reader.set_physical_compaction(frontier.borrow());
        for pin in &mut pins {pin.set_logical_compaction(frontier.borrow());pin.set_physical_compaction(frontier.borrow());}
        logger.flush();
        let t=totals.borrow();rows.push(format!("{},{}",t.0,t.1));
    }
    drop(writer);drop(reader);drop(pins);logger.flush();
    let t=totals.borrow();assert_eq!((t.1,t.2),(0,0));rows.push(format!("{},{}",t.1,t.2));
    rows.join("/")
}
