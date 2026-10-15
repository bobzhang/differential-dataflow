use differential_dataflow::columnar::{updates::{UpdatesTyped,UpdatesBuilder},trie_merger::{merge_pair,suffix_chunk,split_at,extract}};
use timely::{order::Product,container::PushInto,progress::Antichain};
type U=(u32,u32,Product<u64,u64>,i64);
fn text(chunk:&UpdatesTyped<U>)->String {
    chunk.iter().map(|(k,v,t,r)|format!("{},{},{},{},{}",k,v,t.outer,t.inner,r)).collect::<Vec<_>>().join(";")
}
pub fn evaluate(seed:u32)->String {
    let mut state=seed;let mut cases=Vec::new();
    for case in 0..16 {
        let mut inputs=Vec::new();
        for side in 0..2 {
            let mut raw=UpdatesTyped::<U>::default();
            for _ in 0..24 {
                state=state.wrapping_mul(1664525).wrapping_add(1013904223);
                let x=(state>>8)%256;
                if (case+side+seed)%11!=0 {
                    raw.push_into(((x/64,x/16%4),Product::new((x/4%4) as u64,(x%4) as u64),(state%5) as i64-2));
                }
            }
            inputs.push(raw.consolidate());
        }
        let left=inputs.remove(0);let right=inputs.remove(0);
        let left_text=text(&left);let right_text=text(&right);
        let (head,a,b)=if left.len()==0 {(right,None,None)} else if right.len()==0 {(left,None,None)} else {
            let mut a=Some(((0,0,0),left));let mut b=Some(((0,0,0),right));
            let head=merge_pair(&mut a,&mut b).filter_zero();
            (head,a.map(|(cursor,c)|suffix_chunk(cursor,&c).filter_zero()),b.map(|(cursor,c)|suffix_chunk(cursor,&c).filter_zero()))
        };
        let head_text=text(&head);
        let suffix_a=a.as_ref().map(text).unwrap_or_default();let suffix_b=b.as_ref().map(text).unwrap_or_default();
        let mut builder=UpdatesBuilder::new_from(head);
        if let Some(c)=a {builder.meld(&c);}if let Some(c)=b {builder.meld(&c);}
        let full=builder.done();let full_text=text(&full);
        let count=(state as usize)%(full.len()+3);
        let (first,second)=split_at(full.clone(),count);
        let upper=Antichain::from(vec![Product::new(1,3),Product::new(3,1)]);
        let mut frontier=Antichain::new();let mut ready=Vec::new();let mut kept=Vec::new();
        extract(vec![full],upper.borrow(),&mut frontier,|c|ready.push(text(&c)),|c|kept.push(text(&c)));
        let mut times=frontier.elements().to_vec();times.sort();
        let frontier_text=times.iter().map(|t|format!("{},{}",t.outer,t.inner)).collect::<Vec<_>>().join(";");
        cases.push([left_text,right_text,head_text,suffix_a,suffix_b,full_text,text(&first),text(&second),ready.join(""),kept.join(""),frontier_text].join("|"));
    }
    cases.join("/")
}
