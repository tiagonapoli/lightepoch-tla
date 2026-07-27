//! Faithful transcription of the Bf-Tree CPR snapshot phase handshake.
//!
//! Source: bf-tree @ ad17a2e, `src/snapshot.rs`
//!   - `CPRSnapShotMgr::set_local_state`        :297-305
//!   - `CPRSnapShotMgr::advance_global_state`   :308-335
//!   - `CPRSnapShotMgr::check_if_phase_completed` :339-348
//!   - `CPRSnapShotMgr::reserve_thread_slot`    :405-457
//!   - `CPRSnapShotMgr::sweep` (freeze)         :556-560
//!
//! The orderings below are exactly those in the upstream source. `Fix::SeqCst`
//! swaps in the candidate fix so the same harness can show the bug closing.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub const INVALID_SNAPSHOT_STATE: u64 = u64::MAX;
pub const SNAPSHOT_STATE_PHASE_ID_SHIFT: usize = 61;

/// One slot is enough to expose the race; upstream has 64.
pub const SLOTS: usize = 1;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fix {
    /// Upstream orderings: Release stores, Acquire loads. No StoreLoad fence.
    None,
    /// Both sides of the handshake promoted to SeqCst.
    SeqCst,
}

impl Fix {
    fn store(self) -> Ordering {
        match self {
            Fix::None => Ordering::Release,
            Fix::SeqCst => Ordering::SeqCst,
        }
    }

    fn load(self) -> Ordering {
        match self {
            Fix::None => Ordering::Acquire,
            Fix::SeqCst => Ordering::SeqCst,
        }
    }
}

pub fn new_snapshot_state(phase_id: u64, version: u64) -> u64 { (phase_id << SNAPSHOT_STATE_PHASE_ID_SHIFT) | version }

pub struct Mgr {
    global_state: AtomicU64,
    thread_slots: [AtomicBool; SLOTS],
    thread_local_states: [AtomicU64; SLOTS],
    pause_snapshot: AtomicBool,
    fix: Fix,
}

impl Mgr {
    pub fn new(fix: Fix) -> Self {
        Self {
            global_state: AtomicU64::new(new_snapshot_state(0, 0)),
            thread_slots: [const { AtomicBool::new(false) }; SLOTS],
            thread_local_states: [const { AtomicU64::new(INVALID_SNAPSHOT_STATE) }; SLOTS],
            pause_snapshot: AtomicBool::new(false),
            fix,
        }
    }

    /// Republish the initial values as atomic writes.
    ///
    /// GenMC records the constructor's initialization as per-byte non-atomic
    /// writes, and a later 64-bit atomic read of such a location yields only the
    /// low byte, so `INVALID_SNAPSHOT_STATE` comes back as 255. Call this before
    /// any thread starts so every location has a single 64-bit atomic write.
    pub fn publish_initial_state(&self) {
        self.global_state.store(new_snapshot_state(0, 0), Ordering::Relaxed);
        self.pause_snapshot.store(false, Ordering::Relaxed);

        for tid in 0..SLOTS {
            self.thread_slots[tid].store(false, Ordering::Relaxed);
            self.thread_local_states[tid].store(INVALID_SNAPSHOT_STATE, Ordering::Relaxed);
        }
    }

    fn get_local_state(&self, tid: usize) -> u64 { self.thread_local_states[tid].load(self.fix.load()) }

    /// snapshot.rs:297 `set_local_state`
    fn set_local_state(&self, tid: usize, state: u64) {
        if self.get_local_state(tid) == state {
            return;
        }

        self.thread_local_states[tid].store(state, self.fix.store());
    }

    /// snapshot.rs:308 `advance_global_state` — the manager's announce.
    pub fn advance_global_state(&self) -> u64 {
        let version = self.global_state.load(self.fix.load()) & ((1 << SNAPSHOT_STATE_PHASE_ID_SHIFT) - 1);
        let new_state = new_snapshot_state(1, version);
        self.global_state.store(new_state, self.fix.store());

        new_state
    }

    /// snapshot.rs:339 `check_if_phase_completed` — the manager's scan.
    pub fn check_if_phase_completed(&self, target_state: u64) -> bool {
        for tid in 0..SLOTS {
            let local_state = self.thread_local_states[tid].load(self.fix.load());
            if local_state != INVALID_SNAPSHOT_STATE && local_state != target_state {
                return false;
            }
        }

        true
    }

    /// snapshot.rs:556 `sweep` — freeze the tree, then wait for every slot to drain.
    pub fn request_freeze(&self) { self.pause_snapshot.store(true, self.fix.store()); }

    pub fn is_frozen(&self) -> bool { self.check_if_phase_completed(INVALID_SNAPSHOT_STATE) }

    /// snapshot.rs:405 `reserve_thread_slot` — the worker's announce plus the
    /// double-check that is supposed to make the announce safe.
    ///
    /// Returns the state the worker committed to, or `None` if it rolled back.
    pub fn reserve_thread_slot(&self) -> Option<(usize, u64)> {
        if self.pause_snapshot.load(self.fix.load()) {
            return None;
        }

        for tid in 0..SLOTS {
            if self.thread_slots[tid].compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_err() {
                continue;
            }

            let global_state = self.global_state.load(self.fix.load());
            self.set_local_state(tid, global_state);

            // The double-check. Under Release/Acquire this load may be satisfied
            // before the announce store above has left this thread's store buffer.
            let current_global = self.global_state.load(self.fix.load());
            if self.get_local_state(tid) != current_global || self.pause_snapshot.load(self.fix.load()) {
                self.set_local_state(tid, INVALID_SNAPSHOT_STATE);
                assert!(self.thread_slots[tid].compare_exchange(true, false, Ordering::AcqRel, Ordering::Relaxed).is_ok());

                return None;
            }

            return Some((tid, global_state));
        }

        None
    }

    pub fn release_thread_slot(&self, tid: usize) {
        self.set_local_state(tid, INVALID_SNAPSHOT_STATE);
        self.thread_slots[tid].store(false, self.fix.store());
    }
}

unsafe impl Sync for Mgr {}
unsafe impl Send for Mgr {}

/// RustMC ignores Rust panics, so an invariant break has to be reported as a
/// memory-safety fault. A null read surfaces as "Attempt to access
/// non-allocated memory!" with a full execution graph.
#[inline(never)]
pub fn signal_violation() { unsafe { std::ptr::read_volatile(std::ptr::null::<u64>()) }; }
