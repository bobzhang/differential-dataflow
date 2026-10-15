use differential_dataflow::{consolidation::consolidate_updates, trace::{Batch, BatchReader, Batcher, Builder, Cursor, Merger, Navigable, implementations::{ValBatcher, ValBuilder}}};
use timely::{container::PushInto, order::Product, progress::Antichain};
type Time = Product<u64,u64>;
type BuilderType = ValBuilder<u32,u32,Time,i64>;
type BatchType = <BuilderType as Builder>::Output;
fn records(batch: &BatchType) -> String {
    let mut cursor = batch.cursor();
    let mut records = Vec::new();
    while let Some(key) = cursor.get_key(batch).copied() {
        while let Some(val) = cursor.get_val(batch).copied() {
            cursor.map_times(batch, |t,r| records.push((key,val,t.outer,t.inner,*r)));
            cursor.step_val(batch);
        }
        cursor.step_key(batch);
    }
    records.sort();
    records.iter().map(|(k,v,x,y,r)| format!("{},{},{},{},{}",k,v,x,y,r)).collect::<Vec<_>>().join(";")
}
fn frontier(values: &Antichain<Time>) -> String {
    let mut values = values.elements().to_vec();
    values.sort();
    values.iter().map(|t| format!("{},{}",t.outer,t.inner)).collect::<Vec<_>>().join(";")
}
pub fn evaluate(seed: u32) -> String {
    let mut random = seed;
    let mut batcher = ValBatcher::<u32,u32,Time,i64>::new(None,0);
    let mut output = Vec::new();
    let mut batches = Vec::new();
    for epoch in 0..8 {
        for _ in 0..3 {
            let mut updates = Vec::new();
            for _ in 0..16 {
                random = random.wrapping_mul(1664525).wrapping_add(1013904223);
                let index = (random >> 8) % 256;
                updates.push(((index/64,index/16%4),Product::new(epoch+(index/4%4) as u64,epoch+(index%4) as u64),(random%5) as i64-2));
            }
            consolidate_updates(&mut updates);
            batcher.push_into(updates);
        }
        let upper = Antichain::from(vec![Product::new(epoch+1,0),Product::new(0,epoch+1)]);
        let (mut chain,description) = batcher.seal(upper);
        let batch = BuilderType::seal(&mut chain,description);
        output.push(format!("{}|{}",records(&batch),frontier(&batcher.frontier().to_owned())));
        batches.push(batch);
    }
    let (mut chain,description) = batcher.seal(Antichain::new());
    batches.push(BuilderType::seal(&mut chain,description));
    let since = Antichain::from(vec![Product::new(4,2),Product::new(2,4)]);
    let mut merged = batches.remove(0);
    for batch in batches {
        let mut merger = merged.begin_merge(&batch,since.borrow());
        loop {
            let mut fuel = 1;
            merger.work(&merged,&batch,&mut fuel);
            if fuel > 0 { break }
        }
        merged = merger.done();
    }
    output.push(format!("{}|{}",records(&merged),frontier(merged.description().since())));
    output.join("/")
}
