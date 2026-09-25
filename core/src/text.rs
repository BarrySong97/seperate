//! Pinyin search keys, so Chinese titles can be found by typing pinyin ("daima" / "dm" → 代码).

use pinyin::ToPinyin;
use serde::Serialize;

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct PinyinKeys {
    /// One character per input character: the pinyin initial of a hanzi, else the character lowercased.
    pub initials: String,
    /// Full pinyin of hanzi, other characters lowercased as-is.
    pub full: String,
    /// For each character of `full`, the index of the input character it came from.
    pub owner: Vec<usize>,
}

pub fn pinyin_keys(text: &str) -> PinyinKeys {
    let mut initials = String::new();
    let mut full = String::new();
    let mut owner = Vec::new();
    for (i, ch) in text.chars().enumerate() {
        match ch.to_pinyin() {
            Some(p) => {
                initials.push_str(p.first_letter());
                for c in p.plain().chars() {
                    full.push(c);
                    owner.push(i);
                }
            }
            None => {
                let lower: String = ch.to_lowercase().collect();
                // Keep `initials` aligned 1:1 with the input characters.
                initials.push(lower.chars().next().unwrap_or(ch));
                for c in lower.chars() {
                    full.push(c);
                    owner.push(i);
                }
            }
        }
    }
    PinyinKeys { initials, full, owner }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initials_align_with_characters_and_full_maps_back() {
        let k = pinyin_keys("代码同步 v2");
        assert_eq!(k.initials, "dmtb v2");
        assert_eq!(k.initials.chars().count(), "代码同步 v2".chars().count());
        assert_eq!(k.full, "daimatongbu v2");
        assert_eq!(k.owner.len(), k.full.chars().count());
        assert_eq!(k.owner[0..4], [0, 0, 0, 1]); // d a i → 代, m → 码
    }
}
