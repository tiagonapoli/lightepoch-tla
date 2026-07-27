#include <stdatomic.h>
#include <pthread.h>
#include <assert.h>

atomic_int x, y;
int a, b;

void *t1(void *_) { atomic_store_explicit(&x, 1, memory_order_seq_cst); a = atomic_load_explicit(&y, memory_order_seq_cst); return NULL; }
void *t2(void *_) { atomic_store_explicit(&y, 1, memory_order_seq_cst); b = atomic_load_explicit(&x, memory_order_seq_cst); return NULL; }

int main(void)
{
	pthread_t p1, p2;
	pthread_create(&p1, NULL, t1, NULL);
	pthread_create(&p2, NULL, t2, NULL);
	pthread_join(p1, NULL);
	pthread_join(p2, NULL);
	assert(!(a == 0 && b == 0));

	return 0;
}
