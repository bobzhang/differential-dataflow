use differential_dataflow::{operators::arrange::TraceAgent,trace::{Trace,TraceReader,implementations::ValSpine}};
use timely::{dataflow::operators::generic::OperatorInfo,order::Product,progress::Antichain};
type T=Product<u64,u64>;
fn text(f:timely::progress::frontier::AntichainRef<T>)->String {
    let mut values=f.to_vec();values.sort();
    values.iter().map(|t|format!("{},{}",t.outer,t.inner)).collect::<Vec<_>>().join(";")
}
pub fn evaluate(seed:u32)->String {
    let info=OperatorInfo::new(0,0,vec![0].into());
    let spine=ValSpine::<u32,u32,T,i64>::new(info.clone(),None,None);
    let (mut a,writer)=TraceAgent::new(spine,info,None);let mut b=a.clone();
    let mut state=seed;let mut output=Vec::new();
    for _ in 0..32 {
        let mut f=Vec::new();let mut g=Vec::new();
        for _ in 0..2 {
            state=state.wrapping_mul(1664525).wrapping_add(1013904223);
            f.push(Product::new(((state>>8)%9) as u64,((state>>16)%9) as u64));
            state=state.wrapping_mul(1664525).wrapping_add(1013904223);
            g.push(Product::new(((state>>8)%9) as u64,((state>>16)%9) as u64));
        }
        let target=if (state>>24)%2==0 {&mut a} else {&mut b};
        target.set_logical_compaction(Antichain::from(f).borrow());
        target.set_physical_compaction(Antichain::from(g).borrow());
        output.push([text(a.get_logical_compaction()),text(a.get_physical_compaction()),text(b.get_logical_compaction()),text(b.get_physical_compaction())].join("|"));
    }
    a.set_logical_compaction(Antichain::new().borrow());
    a.set_logical_compaction(Antichain::from_elem(Product::new(0,0)).borrow());
    assert!(a.get_logical_compaction().is_empty());
    drop(writer);drop(a);drop(b);
    output.join("/")
}
