//! Sanity checks that RustMC reports what we expect it to report.
//!
//! `always_fails`  — does a plain Rust `assert!` surface as a RustMC failure?
//! `sb_relaxed`    — does RustMC expose the store-buffering outcome at all?
//! `sb_seqcst`     — the same litmus under SeqCst must be clean.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

#[test]
fn always_fails() { assert!(false, "sanity: RustMC must report this test as failing"); }

fn sb(store: Ordering, load: Ordering) {
    static X: AtomicUsize = AtomicUsize::new(0);
    static Y: AtomicUsize = AtomicUsize::new(0);

    X.store(0, Ordering::Relaxed);
    Y.store(0, Ordering::Relaxed);

    let t = thread::spawn(move || {
        X.store(1, store);
        Y.load(load)
    });

    Y.store(1, store);
    let b = X.load(load);
    let a = t.join().unwrap();

    if a == 0 && b == 0 {
        bftree_cpr::signal_violation();
    }
}

#[test]
fn sb_relaxed() { sb(Ordering::Release, Ordering::Acquire); }

#[test]
fn sb_seqcst() { sb(Ordering::SeqCst, Ordering::SeqCst); }
