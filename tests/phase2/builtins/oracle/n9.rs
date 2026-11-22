use std::io::{self, BufRead};
fn main() {
 for line in io::stdin().lock().lines() {
  let line=line.unwrap(); let f:Vec<&str>=line.split('\t').collect();
  let name=f[0]; let id=f[1];
  if name=="fround" {
   let x: f64=if f[2].starts_with("i:") { f[2][2..].parse::<i64>().unwrap() as f64 }
              else { f64::from_bits(u64::from_str_radix(&f[2][2..],16).unwrap()) };
   println!("{}\t{}\tfloat\t{:016x}",name,id,(x as f32 as f64).to_bits()); continue;
  }
  let a=f[2].parse::<i64>().unwrap(); let b=f.get(3).unwrap_or(&"0").parse::<i64>().unwrap();
  let (answer,kind)=match name {
            "i8_wrapping_add" => (Some(((a as i8).wrapping_add(b as i8) as i64).to_string()), "int"),
            "i8_wrapping_sub" => (Some(((a as i8).wrapping_sub(b as i8) as i64).to_string()), "int"),
            "i8_wrapping_mul" => (Some(((a as i8).wrapping_mul(b as i8) as i64).to_string()), "int"),
            "i8_checked_add" => ((a as i8).checked_add(b as i8).map(|x| (x as i64).to_string()), "int"),
            "i8_checked_sub" => ((a as i8).checked_sub(b as i8).map(|x| (x as i64).to_string()), "int"),
            "i8_checked_mul" => ((a as i8).checked_mul(b as i8).map(|x| (x as i64).to_string()), "int"),
            "i8_saturating_add" => (Some(((a as i8).saturating_add(b as i8) as i64).to_string()), "int"),
            "i8_saturating_sub" => (Some(((a as i8).saturating_sub(b as i8) as i64).to_string()), "int"),
            "i8_saturating_mul" => (Some(((a as i8).saturating_mul(b as i8) as i64).to_string()), "int"),
            "i16_wrapping_add" => (Some(((a as i16).wrapping_add(b as i16) as i64).to_string()), "int"),
            "i16_wrapping_sub" => (Some(((a as i16).wrapping_sub(b as i16) as i64).to_string()), "int"),
            "i16_wrapping_mul" => (Some(((a as i16).wrapping_mul(b as i16) as i64).to_string()), "int"),
            "i16_checked_add" => ((a as i16).checked_add(b as i16).map(|x| (x as i64).to_string()), "int"),
            "i16_checked_sub" => ((a as i16).checked_sub(b as i16).map(|x| (x as i64).to_string()), "int"),
            "i16_checked_mul" => ((a as i16).checked_mul(b as i16).map(|x| (x as i64).to_string()), "int"),
            "i16_saturating_add" => (Some(((a as i16).saturating_add(b as i16) as i64).to_string()), "int"),
            "i16_saturating_sub" => (Some(((a as i16).saturating_sub(b as i16) as i64).to_string()), "int"),
            "i16_saturating_mul" => (Some(((a as i16).saturating_mul(b as i16) as i64).to_string()), "int"),
            "i32_wrapping_add" => (Some(((a as i32).wrapping_add(b as i32) as i64).to_string()), "int"),
            "i32_wrapping_sub" => (Some(((a as i32).wrapping_sub(b as i32) as i64).to_string()), "int"),
            "i32_wrapping_mul" => (Some(((a as i32).wrapping_mul(b as i32) as i64).to_string()), "int"),
            "i32_checked_add" => ((a as i32).checked_add(b as i32).map(|x| (x as i64).to_string()), "int"),
            "i32_checked_sub" => ((a as i32).checked_sub(b as i32).map(|x| (x as i64).to_string()), "int"),
            "i32_checked_mul" => ((a as i32).checked_mul(b as i32).map(|x| (x as i64).to_string()), "int"),
            "i32_saturating_add" => (Some(((a as i32).saturating_add(b as i32) as i64).to_string()), "int"),
            "i32_saturating_sub" => (Some(((a as i32).saturating_sub(b as i32) as i64).to_string()), "int"),
            "i32_saturating_mul" => (Some(((a as i32).saturating_mul(b as i32) as i64).to_string()), "int"),
            "i64_wrapping_add" => (Some(((a as i64).wrapping_add(b as i64) as i64).to_string()), "int"),
            "i64_wrapping_sub" => (Some(((a as i64).wrapping_sub(b as i64) as i64).to_string()), "int"),
            "i64_wrapping_mul" => (Some(((a as i64).wrapping_mul(b as i64) as i64).to_string()), "int"),
            "i64_checked_add" => ((a as i64).checked_add(b as i64).map(|x| (x as i64).to_string()), "int"),
            "i64_checked_sub" => ((a as i64).checked_sub(b as i64).map(|x| (x as i64).to_string()), "int"),
            "i64_checked_mul" => ((a as i64).checked_mul(b as i64).map(|x| (x as i64).to_string()), "int"),
            "i64_saturating_add" => (Some(((a as i64).saturating_add(b as i64) as i64).to_string()), "int"),
            "i64_saturating_sub" => (Some(((a as i64).saturating_sub(b as i64) as i64).to_string()), "int"),
            "i64_saturating_mul" => (Some(((a as i64).saturating_mul(b as i64) as i64).to_string()), "int"),
            "u8_wrapping_add" => (Some(((a as u8).wrapping_add(b as u8) as i64).to_string()), "int"),
            "u8_wrapping_sub" => (Some(((a as u8).wrapping_sub(b as u8) as i64).to_string()), "int"),
            "u8_wrapping_mul" => (Some(((a as u8).wrapping_mul(b as u8) as i64).to_string()), "int"),
            "u8_checked_add" => ((a as u8).checked_add(b as u8).map(|x| (x as i64).to_string()), "int"),
            "u8_checked_sub" => ((a as u8).checked_sub(b as u8).map(|x| (x as i64).to_string()), "int"),
            "u8_checked_mul" => ((a as u8).checked_mul(b as u8).map(|x| (x as i64).to_string()), "int"),
            "u8_saturating_add" => (Some(((a as u8).saturating_add(b as u8) as i64).to_string()), "int"),
            "u8_saturating_sub" => (Some(((a as u8).saturating_sub(b as u8) as i64).to_string()), "int"),
            "u8_saturating_mul" => (Some(((a as u8).saturating_mul(b as u8) as i64).to_string()), "int"),
            "u16_wrapping_add" => (Some(((a as u16).wrapping_add(b as u16) as i64).to_string()), "int"),
            "u16_wrapping_sub" => (Some(((a as u16).wrapping_sub(b as u16) as i64).to_string()), "int"),
            "u16_wrapping_mul" => (Some(((a as u16).wrapping_mul(b as u16) as i64).to_string()), "int"),
            "u16_checked_add" => ((a as u16).checked_add(b as u16).map(|x| (x as i64).to_string()), "int"),
            "u16_checked_sub" => ((a as u16).checked_sub(b as u16).map(|x| (x as i64).to_string()), "int"),
            "u16_checked_mul" => ((a as u16).checked_mul(b as u16).map(|x| (x as i64).to_string()), "int"),
            "u16_saturating_add" => (Some(((a as u16).saturating_add(b as u16) as i64).to_string()), "int"),
            "u16_saturating_sub" => (Some(((a as u16).saturating_sub(b as u16) as i64).to_string()), "int"),
            "u16_saturating_mul" => (Some(((a as u16).saturating_mul(b as u16) as i64).to_string()), "int"),
            "u32_wrapping_add" => (Some(((a as u32).wrapping_add(b as u32) as i64).to_string()), "int"),
            "u32_wrapping_sub" => (Some(((a as u32).wrapping_sub(b as u32) as i64).to_string()), "int"),
            "u32_wrapping_mul" => (Some(((a as u32).wrapping_mul(b as u32) as i64).to_string()), "int"),
            "u32_checked_add" => ((a as u32).checked_add(b as u32).map(|x| (x as i64).to_string()), "int"),
            "u32_checked_sub" => ((a as u32).checked_sub(b as u32).map(|x| (x as i64).to_string()), "int"),
            "u32_checked_mul" => ((a as u32).checked_mul(b as u32).map(|x| (x as i64).to_string()), "int"),
            "u32_saturating_add" => (Some(((a as u32).saturating_add(b as u32) as i64).to_string()), "int"),
            "u32_saturating_sub" => (Some(((a as u32).saturating_sub(b as u32) as i64).to_string()), "int"),
            "u32_saturating_mul" => (Some(((a as u32).saturating_mul(b as u32) as i64).to_string()), "int"),
            "u64_wrapping_add" => (Some(((a as u64).wrapping_add(b as u64) as i64).to_string()), "int"),
            "u64_wrapping_sub" => (Some(((a as u64).wrapping_sub(b as u64) as i64).to_string()), "int"),
            "u64_wrapping_mul" => (Some(((a as u64).wrapping_mul(b as u64) as i64).to_string()), "int"),
            "u64_checked_add" => ((a as u64).checked_add(b as u64).map(|x| (x as i64).to_string()), "int"),
            "u64_checked_sub" => ((a as u64).checked_sub(b as u64).map(|x| (x as i64).to_string()), "int"),
            "u64_checked_mul" => ((a as u64).checked_mul(b as u64).map(|x| (x as i64).to_string()), "int"),
            "u64_saturating_add" => (Some(((a as u64).saturating_add(b as u64) as i64).to_string()), "int"),
            "u64_saturating_sub" => (Some(((a as u64).saturating_sub(b as u64) as i64).to_string()), "int"),
            "u64_saturating_mul" => (Some(((a as u64).saturating_mul(b as u64) as i64).to_string()), "int"),
   "u64_compare" => (Some(((a as u64).cmp(&(b as u64)) as i8).to_string()), "int"),
   "u64_div" => ((a as u64).checked_div(b as u64).map(|x| (x as i64).to_string()), "int"),
   "u64_rem" => ((a as u64).checked_rem(b as u64).map(|x| (x as i64).to_string()), "int"),
   "u64_to_string" => (Some((a as u64).to_string()), "string"),
   _ => panic!("unknown op {}",name)
  };
  match answer {
   Some(value)=>println!("{}\t{}\t{}\t{}",name,id,kind,value),
   None=>println!("{}\t{}\tnone\t-",name,id)
  }
 }
}
