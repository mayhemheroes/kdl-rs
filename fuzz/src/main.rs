#[macro_use]
extern crate afl;
extern crate kdl;

use kdl::KdlDocument;

fn main() {
    fuzz!(|data: &str| {
        let _ = data.parse::<KdlDocument>();
    });
}
