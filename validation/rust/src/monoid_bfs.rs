use differential_dataflow::{input::Input, operators::iterate::Variable,
    difference::{IsZero, Semigroup, Multiply}, trace::implementations::{KeyBuilder,KeySpine}};
use timely::order::Product;
use std::{cell::RefCell, rc::Rc, collections::BTreeMap};
#[derive(Clone,Copy,Debug,Eq,PartialEq,Ord,PartialOrd,serde::Serialize,serde::Deserialize)]
struct MinSum(u32);
impl IsZero for MinSum { fn is_zero(&self)->bool { false } }
impl Semigroup for MinSum { fn plus_equals(&mut self, other:&Self) { self.0=self.0.min(other.0); } }
impl Multiply for MinSum { type Output=Self; fn multiply(self, other:&Self)->Self { Self(self.0+other.0) } }
pub fn evaluate(seed:u32)->String {
    timely::execute_directly(move |worker| {
        let distances=Rc::new(RefCell::new(BTreeMap::<u32,u32>::new()));
        let sink=distances.clone();
        let (mut edges,mut roots,probe)=worker.dataflow::<u64,_,_>(|outer| {
            let (edges,graph)=outer.new_collection::<(u32,u32),MinSum>();
            let (roots,starts)=outer.new_collection::<u32,MinSum>();
            let result=outer.iterative::<u64,_,_>(|inner| {
                let (variable,collection)=Variable::new(inner,Product::new(0,1));
                let result=collection.map(|n|(n,())).join_map(graph.enter(inner),|_,&(),d|*d)
                    .concat(starts.enter(inner)).map(|n|(n,()))
                    .reduce_core::<_,KeyBuilder<u32,Product<u64,u64>,MinSum>,KeySpine<u32,Product<u64,u64>,MinSum>>(
                        "MinSum",|_,input,output,changes| {
                            if !input.is_empty() && (output.is_empty() || input[0].1<output[0].1) {
                                changes.push(((),input[0].1));
                            }
                        }).as_collection(|k,()|*k);
                variable.set(result.clone());
                result.leave(outer)
            });
            let (probe,_)=result.inspect(move |&(node,_,MinSum(value))| {
                sink.borrow_mut().entry(node).and_modify(|old|*old=(*old).min(value)).or_insert(value);
            }).probe();
            (edges,roots,probe)
        });
        let mut random=seed;
        let mut rows=Vec::new();
        for epoch in 0..16u64 {
            if epoch==0 || epoch==8 {
                random=random.wrapping_mul(1664525).wrapping_add(1013904223);
                roots.update((random>>8)%12,MinSum(0));
            }
            for _ in 0..4 {
                random=random.wrapping_mul(1664525).wrapping_add(1013904223);
                let i=(random>>8)%144;
                edges.update((i/12,i%12),MinSum(random%10));
            }
            roots.advance_to(epoch+1);roots.flush();
            edges.advance_to(epoch+1);edges.flush();
            while probe.less_than(&(epoch+1)) { worker.step(); }
            rows.push(distances.borrow().iter().map(|(k,v)|format!("{k},{v}")).collect::<Vec<_>>().join(";"));
        }
        roots.close();edges.close();
        while !probe.done() {worker.step();}
        rows.join("/")
    })
}
