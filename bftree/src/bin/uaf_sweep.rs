//! Scenario B — use-after-free, the Rust/Miri analogue of the poison-page repro.
//!
//! In the C# repro the reclaimer unmaps a page and the ARM64 MMU reports the
//! reader's dereference as 0xC0000005. Here the manager frees a `Box` and Miri
//! reports the worker's dereference as UB. Miri replaces the MMU: the detection
//! is deterministic, architecture-independent, and points at the exact access.
//!
//! Models `CPRSnapShotMgr::sweep` (snapshot.rs:556-560):
//!   Manager: STORE pause_snapshot=true ; scan slots ; "tree is frozen, take it"
//!   Worker:  STORE thread_local_states[tid] ; LOAD pause_snapshot ; "I hold a slot, use the tree"
//!
//! Both sides store-then-load the other's location under Release/Acquire, so
//! both loads can miss both stores: the manager frees the tree while the worker
//! is inside it.
//!
//!   cargo +nightly miri run --bin uaf_sweep
//!   cargo +nightly miri run --bin uaf_sweep -- fix

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use bftree_cpr::{Fix, Mgr};

struct InnerNode {
    magic: u64,
}

fn main() {
    let fix = if std::env::args().any(|a| a == "fix") { Fix::SeqCst } else { Fix::None };
    let iters: usize = std::env::var("ITERS").ok().and_then(|v| v.parse().ok()).unwrap_or(300);
    println!("uaf_sweep: fix={:?} iters={}", fix, iters);

    for i in 0..iters {
        let mgr = Arc::new(Mgr::new(fix));
        let node: *mut InnerNode = Box::into_raw(Box::new(InnerNode { magic: 0x5AFE_0000_5AFE }));
        let freed = Arc::new(AtomicBool::new(false));

        let worker_mgr = mgr.clone();
        let node_addr = node as usize;
        let worker = thread::spawn(move || {
            let Some((tid, _)) = worker_mgr.reserve_thread_slot() else {
                return false;
            };

            // The worker holds a slot, so by the protocol the tree is not frozen
            // and this pointer is live. Miri faults here when that is false.
            let n = unsafe { &*(node_addr as *const InnerNode) };
            assert_eq!(n.magic, 0x5AFE_0000_5AFE);

            worker_mgr.release_thread_slot(tid);

            true
        });

        mgr.request_freeze();
        if mgr.is_frozen() {
            // The scan says no worker holds a slot, so the manager takes
            // exclusive ownership of the tree structure.
            unsafe { drop(Box::from_raw(node)) };
            freed.store(true, Ordering::SeqCst);
        }

        let _ = worker.join().unwrap();

        if !freed.load(Ordering::SeqCst) {
            unsafe { drop(Box::from_raw(node)) };
        }

        if i % 50 == 0 {
            println!("  iteration {} ok", i);
        }
    }

    println!("no use-after-free observed in {} iterations", iters);
}
