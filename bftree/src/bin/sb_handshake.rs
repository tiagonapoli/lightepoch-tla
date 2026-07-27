//! Scenario A — the phase-transition handshake as a litmus test.
//!
//! Worker  (snapshot.rs:421,432): STORE thread_local_states[tid] ; LOAD global_state
//! Manager (snapshot.rs:332,342): STORE global_state             ; LOAD thread_local_states[tid]
//!
//! Store-buffering. The outcome asserted against is impossible under sequential
//! consistency but permitted by Release/Acquire: the worker commits to the OLD
//! phase while the manager concludes every thread reached the NEW phase.
//!
//!   cargo +nightly miri run --bin sb_handshake
//!   cargo +nightly miri run --bin sb_handshake -- fix

use std::sync::Arc;
use std::thread;

use bftree_cpr::{Fix, Mgr};

fn main() {
    let fix = if std::env::args().any(|a| a == "fix") { Fix::SeqCst } else { Fix::None };
    let iters: usize = std::env::var("ITERS").ok().and_then(|v| v.parse().ok()).unwrap_or(300);
    println!("sb_handshake: fix={:?} iters={}", fix, iters);

    for i in 0..iters {
        let mgr = Arc::new(Mgr::new(fix));

        let worker_mgr = mgr.clone();
        let worker = thread::spawn(move || worker_mgr.reserve_thread_slot());

        let new_state = mgr.advance_global_state();
        let phase_completed = mgr.check_if_phase_completed(new_state);

        let reserved = worker.join().unwrap();

        if let Some((_tid, committed_state)) = reserved {
            if committed_state != new_state && phase_completed {
                println!();
                println!("VIOLATION at iteration {}", i);
                println!("  worker committed to state 0x{:x} (the OLD phase)", committed_state);
                println!("  manager advanced to    0x{:x} (the NEW phase)", new_state);
                println!("  manager's scan reported phase_completed = true");
                println!();
                println!("The manager will now run the new phase's action while a worker is");
                println!("still live in the old phase. This is exactly the interleaving that");
                println!("snapshot.rs:426-431 claims the double-check prevents.");
                std::process::exit(1);
            }
        }
    }

    println!("no violation observed in {} iterations", iters);
}
