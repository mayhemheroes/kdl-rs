#![no_main]
use libfuzzer_sys::fuzz_target;
use kdl::KdlDocument;

// Port of the old AFL harness (fuzz/src/main.rs). The old one used `.expect(...)`,
// which panicked on EVERY malformed input — that makes every bad input a "crash"
// and defeats fuzzing. We drop the expect and ignore the Result so the fuzzer
// exercises the parser and only a real panic / UB / memory bug in kdl crashes.
fuzz_target!(|data: &[u8]| {
    if let Ok(s) = std::str::from_utf8(data) {
        let _ = s.parse::<KdlDocument>();
    }
});
