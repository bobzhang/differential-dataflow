use differential_dataflow::{consolidation::consolidate_updates, trace::{Builder, Cursor, Description, cursor::cursor_list, implementations::ValBuilder}};
use timely::progress::Antichain;

pub fn evaluate(seed: u32) -> String {
    let mut random = seed;
    let mut batches = Vec::new();
    for epoch in 0u64..8 {
        let mut updates = Vec::new();
        for _ in 0..32 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = (random >> 8) % 64;
            updates.push(((index / 8, index % 8), epoch, (random % 5) as i64 - 2));
        }
        updates.push(((9, 9), epoch, 1));
        consolidate_updates(&mut updates);
        let batch = ValBuilder::<u32, u32, u64, i64>::seal(&mut vec![updates], Description::new(Antichain::from_elem(epoch), Antichain::from_elem(epoch+1), Antichain::from_elem(epoch)));
        batches.push(batch);
    }
    let (mut cursor, storage) = cursor_list(batches);
    let mut output = Vec::new();
    for _ in 0..128 {
        random = random.wrapping_mul(1664525).wrapping_add(1013904223);
        let target = (random >> 8) % 10;
        match random % 6 {
            0 => cursor.step_key(&storage),
            1 => cursor.step_val(&storage),
            2 => cursor.seek_key(&storage, &target),
            3 => { if cursor.key_valid(&storage) { cursor.seek_val(&storage, &target); } },
            4 => cursor.rewind_keys(&storage),
            _ => cursor.rewind_vals(&storage),
        }
        let key = cursor.get_key(&storage).map_or(-1, |x| *x as i64);
        let value = cursor.get_val(&storage).map_or(-1, |x| *x as i64);
        let mut times = Vec::new();
        if cursor.val_valid(&storage) { cursor.map_times(&storage, |t,r| times.push((*t,*r))); }
        times.sort();
        output.push(format!("{},{}|{}",key,value,times.iter().map(|(t,r)| format!("{},{}",t,r)).collect::<Vec<_>>().join(";")));
    }
    output.join("/")
}
