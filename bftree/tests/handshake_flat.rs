//! The bf-tree CPR handshake written flat, with static atomics and the
//! orderings hardcoded, so nothing about the harness can mask the outcome.
//!
//! Worker  (snapshot.rs:421,432): STORE thread_local_state ; LOAD global_state
//! Manager (snapshot.rs:332,342): STORE global_state       ; LOAD thread_local_state

use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

use bftree_cpr::signal_violation;

const INVALID: u64 = u64::MAX;
const OLD: u64 = 0;
const NEW: u64 = 1 << 61;

static GLOBAL_STATE: AtomicU64 = AtomicU64::new(OLD);
static LOCAL_STATE: AtomicU64 = AtomicU64::new(INVALID);

fn run(store: Ordering, load: Ordering) {
    GLOBAL_STATE.store(OLD, Ordering::Relaxed);
    LOCAL_STATE.store(INVALID, Ordering::Relaxed);

    let worker = thread::spawn(move || {
        let g = GLOBAL_STATE.load(load);
        LOCAL_STATE.store(g, store);
        let recheck = GLOBAL_STATE.load(load);
        if recheck != g {
            LOCAL_STATE.store(INVALID, store);

            return INVALID;
        }

        g
    });

    GLOBAL_STATE.store(NEW, store);
    let seen = LOCAL_STATE.load(load);
    let phase_completed = seen == INVALID || seen == NEW;

    let committed = worker.join().unwrap();

    if committed != INVALID && committed != NEW && phase_completed {
        signal_violation();
    }
}

#[test]
fn flat_upstream() { run(Ordering::Release, Ordering::Acquire); }

#[test]
fn flat_seqcst() { run(Ordering::SeqCst, Ordering::SeqCst); }
