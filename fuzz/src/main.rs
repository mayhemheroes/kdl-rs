#[macro_use]
extern crate afl;
extern crate kdl;

use kdl::KdlDocument;

fn main() {
    fuzz!(|data: &[u8]| {
        if let Ok(s) = std::str::from_utf8(data) {
            let _doc: KdlDocument = s.parse().expect("Failed to parse KDL document");
        }
    });
}
