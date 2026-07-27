//! RustMC / GenMC entry points for the Bf-Tree CPR handshake.
//!
//!   docker run --rm -v "${PWD}:/w" -w /w rustmc:v03 cargo rustmc test
//!
//! `handshake_upstream` uses the orderings from bf-tree @ ad17a2e; it must fail.
//! `handshake_seqcst` uses the candidate fix; it must pass.

use bftree_cpr::{Fix, Mgr};

fn run(fix: Fix) {
    let mgr: &'static Mgr = Box::leak(Box::new(Mgr::new(fix)));
    mgr.publish_initial_state();

    let worker = std::thread::spawn(move || mgr.reserve_thread_slot());

    let new_state = mgr.advance_global_state();
    let phase_completed = mgr.check_if_phase_completed(new_state);

    let reserved = worker.join().unwrap();

    if let Some((_tid, committed_state)) = reserved {
        if committed_state != new_state && phase_completed {
            bftree_cpr::signal_violation();
        }
    }
}

#[test]
fn handshake_upstream() { run(Fix::None); }

#[test]
fn handshake_seqcst() { run(Fix::SeqCst); }
