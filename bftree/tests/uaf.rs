//! Use-after-free port of `sweep()`'s freeze, as RustMC test functions.
//!
//! RustMC does not treat a Rust `assert!` panic as an error, so the violation
//! has to be expressed as a memory-safety fault: when the handshake breaks, the
//! manager frees the node the worker is about to dereference. GenMC reports the
//! access to freed memory, which is the model-checker equivalent of the poison
//! page in the C# LightEpoch repro.
//!
//! Models snapshot.rs:556-560 against snapshot.rs:421,434.

use bftree_cpr::{Fix, Mgr};

struct InnerNode {
    magic: u64,
}

fn run(fix: Fix) {
    let mgr: &'static Mgr = Box::leak(Box::new(Mgr::new(fix)));
    mgr.publish_initial_state();

    let node: *mut InnerNode = Box::into_raw(Box::new(InnerNode { magic: 0x5AFE_0000_5AFE }));
    let node_addr = node as usize;

    let worker = std::thread::spawn(move || {
        let Some((tid, _)) = mgr.reserve_thread_slot() else {
            return;
        };

        let n = unsafe { &*(node_addr as *const InnerNode) };
        std::hint::black_box(n.magic);

        mgr.release_thread_slot(tid);
    });

    mgr.request_freeze();
    let frozen = mgr.is_frozen();
    if frozen {
        unsafe { drop(Box::from_raw(node)) };
    }

    worker.join().unwrap();

    if !frozen {
        unsafe { drop(Box::from_raw(node)) };
    }
}

#[test]
fn sweep_upstream() { run(Fix::None); }

#[test]
fn sweep_seqcst() { run(Fix::SeqCst); }
