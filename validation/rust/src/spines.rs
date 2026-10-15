use differential_dataflow::{consolidation::consolidate_updates, trace::{Builder, Cursor, Description, Trace, TraceReader, implementations::{ValSpine, ValBuilder}}};
use timely::{dataflow::operators::generic::OperatorInfo, progress::Antichain};
pub fn evaluate(seed: u32) -> String {
    let mut spine = ValSpine::<u32,u32,u64,i64>::new(OperatorInfo::new(0,0,vec![0].into()),None,None);
    spine.set_exert_logic(std::sync::Arc::new(|_| Some(1)));
    let mut random = seed;
    let mut output = Vec::new();
    for epoch in 0u64..32 {
        let mut updates = Vec::new();
        for _ in 0..12 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = (random >> 8) % 64;
            updates.push(((index/8,index%8),epoch,(random%5) as i64-2));
        }
        consolidate_updates(&mut updates);
        let batch = ValBuilder::<u32,u32,u64,i64>::seal(&mut vec![updates],Description::new(Antichain::from_elem(epoch),Antichain::from_elem(epoch+1),Antichain::from_elem(0)));
        spine.set_logical_compaction(Antichain::from_elem(epoch.saturating_sub(3)).borrow());
        spine.set_physical_compaction(Antichain::from_elem(epoch.saturating_sub(2)).borrow());
        spine.insert(batch);
        spine.exert();
        spine.exert();
        let mut snapshots = Vec::new();
        for query in epoch.saturating_sub(3)..=epoch {
            let (mut cursor, storage) = spine.cursor();
            let mut records = Vec::new();
            while let Some(key) = cursor.get_key(&storage).copied() {
                while let Some(value) = cursor.get_val(&storage).copied() {
                    let mut sum = 0;
                    cursor.map_times(&storage, |t,r| if *t <= query { sum += *r });
                    if sum != 0 { records.push(format!("{},{},{}",key,value,sum)); }
                    cursor.step_val(&storage);
                }
                cursor.step_key(&storage);
            }
            snapshots.push(records.join(";"));
        }
        output.push(snapshots.join("|"));
    }
    spine.close();
    let mut upper = Antichain::new();
    spine.read_upper(&mut upper);
    assert!(upper.is_empty());
    output.join("/")
}
