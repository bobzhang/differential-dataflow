use differential_dataflow::columnar::{updates::{UpdatesTyped,Updates},layout::ColumnarUpdate};
use timely::{container::PushInto,order::Product};
fn encode<U:ColumnarUpdate>(trie:UpdatesTyped<U>)->String {
    let stored:Updates<U>=trie.into();let mut bytes=Vec::new();stored.write_to(&mut bytes);
    assert_eq!(stored.length_in_bytes(),bytes.len());
    let decoded=Updates::<U>::read_from(timely::bytes::arc::BytesMut::from(bytes.clone()).freeze());
    let mut roundtrip=Vec::new();decoded.write_to(&mut roundtrip);assert_eq!(bytes,roundtrip);
    bytes.iter().map(|b|format!("{:02x}",b)).collect()
}
pub fn evaluate(seed:u32)->String {
    let mut state=seed;
    let mut strings=UpdatesTyped::<(u32,String,Product<u64,u64>,i64)>::default();
    let mut numbers=UpdatesTyped::<(u32,u32,u64,i64)>::default();
    let mut nested=UpdatesTyped::<(bool,Vec<u16>,std::time::Duration,i32)>::default();
    let mut small=UpdatesTyped::<((),(i8,i16),u64,i64)>::default();
    let words=["","a","long","月","🦀","\u{feff}x","null\0byte"];
    let count=if seed%8==0 {0} else {65+seed%8};
    for i in 0..count {
        state=state.wrapping_mul(1664525).wrapping_add(1013904223);
        let time=((state as u64)<<32)|(u32::MAX-state) as u64;
        strings.push_into(((state%13,words[(state as usize>>8)%words.len()].to_string()),Product::new(time,i as u64),(state as i64)-2147483648));
        numbers.push_into(((state%7,state%5),time%9,(state%5) as i64-2));
        nested.push_into(((state%2!=0,(0..i%4).map(|j|(state.wrapping_add(j)) as u16).collect()),std::time::Duration::new(time,(state%1000000000) as u32),state as i32));
        small.push_into((((),(state as i8,(state>>8) as i16)),time,-(state as i64)));
    }
    [encode(strings),encode(numbers.consolidate()),encode(nested),encode(small)].join("|")
}
