/* GenMC model of the Bf-Tree CPR snapshot phase handshake.
 *
 * Source: bf-tree @ ad17a2e, src/snapshot.rs
 *   worker  : reserve_thread_slot      :421 store, :432 load
 *   manager : advance_global_state     :332 store
 *             check_if_phase_completed :342 load
 *
 * Rust atomics are C11 atomics, so Release/Acquire transliterate directly.
 * This C version runs on stock `genmc` with no extra configuration; see
 * cpr_handshake.rs for the RustMC (genmc -DENABLE_RUST=ON) version.
 *
 *   genmc -- cpr_handshake.c          # upstream orderings -> assertion violation
 *   genmc -- -DFIX cpr_handshake.c    # SeqCst             -> no violation
 *
 * GenMC explores every consistent execution, so a clean run is a proof of
 * absence under the model, not merely absence of evidence.
 */

#include <assert.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>

#ifdef FIX
#define ST memory_order_seq_cst
#define LD memory_order_seq_cst
#else
#define ST memory_order_release
#define LD memory_order_acquire
#endif

#define INVALID_SNAPSHOT_STATE UINT64_MAX
#define OLD_STATE 0u
#define NEW_STATE 1u

static _Atomic uint64_t global_state;
static _Atomic uint64_t thread_local_state; /* thread_local_states[0] */
static _Atomic int thread_slot;             /* thread_slots[0] */

/* Observations, read only after both threads join. */
static _Atomic uint64_t committed_state;
static _Atomic int committed;
static _Atomic int phase_completed;

/* snapshot.rs:405 reserve_thread_slot */
static void *worker(void *arg)
{
	int expected = 0;

	(void)arg;

	if (!atomic_compare_exchange_strong_explicit(&thread_slot, &expected, 1, memory_order_acq_rel, memory_order_relaxed))
		return NULL;

	uint64_t g = atomic_load_explicit(&global_state, LD);              /* :420 */
	atomic_store_explicit(&thread_local_state, g, ST);                 /* :421 -> :304 announce */

	uint64_t current_global = atomic_load_explicit(&global_state, LD); /* :432 double-check */
	if (g != current_global) {
		atomic_store_explicit(&thread_local_state, INVALID_SNAPSHOT_STATE, ST);
		atomic_store_explicit(&thread_slot, 0, ST);

		return NULL;
	}

	atomic_store_explicit(&committed_state, g, memory_order_relaxed);
	atomic_store_explicit(&committed, 1, memory_order_relaxed);

	return NULL;
}

/* snapshot.rs:308 advance_global_state + :339 check_if_phase_completed */
static void *manager(void *arg)
{
	(void)arg;

	atomic_store_explicit(&global_state, NEW_STATE, ST);                 /* :332 */

	uint64_t local = atomic_load_explicit(&thread_local_state, LD);      /* :342 scan */
	int done = (local == INVALID_SNAPSHOT_STATE || local == NEW_STATE);
	atomic_store_explicit(&phase_completed, done, memory_order_relaxed);

	return NULL;
}

int main(void)
{
	pthread_t tw, tm;

	atomic_init(&global_state, OLD_STATE);
	atomic_init(&thread_local_state, INVALID_SNAPSHOT_STATE);
	atomic_init(&thread_slot, 0);
	atomic_init(&committed, 0);
	atomic_init(&committed_state, INVALID_SNAPSHOT_STATE);
	atomic_init(&phase_completed, 0);

	pthread_create(&tw, NULL, worker, NULL);
	pthread_create(&tm, NULL, manager, NULL);
	pthread_join(tw, NULL);
	pthread_join(tm, NULL);

	/* The invariant snapshot.rs:426-431 claims the double-check establishes:
	 * the manager must never conclude the phase is complete while a worker is
	 * still committed to the old phase. */
	int worker_live_in_old_phase = atomic_load_explicit(&committed, memory_order_relaxed) &&
	                               atomic_load_explicit(&committed_state, memory_order_relaxed) != NEW_STATE;

	assert(!(worker_live_in_old_phase && atomic_load_explicit(&phase_completed, memory_order_relaxed)));

	return 0;
}
