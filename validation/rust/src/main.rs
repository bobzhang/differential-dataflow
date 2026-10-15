use std::io::{self, BufRead};
use timely::order::Product;
use timely::progress::{Antichain, frontier::MutableAntichain};
use differential_dataflow::lattice::Lattice;
fn evaluate(seed: u32) -> String {
    let mut random = seed;
    let mut frontier = MutableAntichain::<Product<i64,i64>>::new();
    let mut result = Vec::new();
    for _ in 0..40 {
        let mut updates = Vec::new();
        for _ in 0..3 {
            random = random.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = ((random >> 8) % 25) as i64;
            let delta = if random % 3 == 0 { -1 } else { 1 };
            updates.push((Product::new(index / 5, index % 5), delta));
        }
        let mut changes: Vec<_> = frontier.update_iter(updates).collect();
        changes.sort();
        let mut minimal = frontier.frontier().to_vec(); minimal.sort();
        let antichain: Antichain<_> = minimal.iter().cloned().collect();
        let mut time = Product::new((seed % 5) as i64, ((seed / 5) % 5) as i64);
        time.advance_by(antichain.borrow());
        result.push(format!("{}|{}|{},{}",
            changes.iter().map(|(t,d)| format!("{},{},{}",t.outer,t.inner,d)).collect::<Vec<_>>().join(";"),
            minimal.iter().map(|t| format!("{},{}",t.outer,t.inner)).collect::<Vec<_>>().join(";"),
            time.outer,time.inner));
    }
    result.join("/")
}
fn main() {
    for line in io::stdin().lock().lines() { println!("{}", evaluate(line.unwrap().parse().unwrap())); }
}
