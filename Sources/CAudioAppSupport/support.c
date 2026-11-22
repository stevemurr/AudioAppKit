#include "CAudioAppSupport.h"
#include <pthread.h>
#include <stddef.h>

#if defined(__x86_64__)
#include <pmmintrin.h>
#include <xmmintrin.h>
#endif

// libmalloc calls this, when set, on every allocation and deallocation in the process. It is
// the hook the system's own allocation logging uses.
typedef void(aak_malloc_logger)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                                uintptr_t result, uint32_t frames_to_skip);
extern aak_malloc_logger *malloc_logger;

static pthread_key_t probe_key;
static pthread_once_t probe_once = PTHREAD_ONCE_INIT;
static aak_malloc_logger *previous_logger;

// Runs inside malloc, so it must not allocate. The thread's counts are reached through a
// pthread key, not a thread-local variable, because a thread-local's first use allocates.
static void probe_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                         uintptr_t result, uint32_t frames_to_skip) {
    aak_probe_counts *counts = pthread_getspecific(probe_key);
    if (counts) {
        if (type & 2) counts->allocations += 1;
        if (type & 4) counts->deallocations += 1;
    }
    if (previous_logger) previous_logger(type, arg1, arg2, arg3, result, frames_to_skip + 1);
}

static void probe_install(void) {
    pthread_key_create(&probe_key, NULL);
    previous_logger = malloc_logger;
    malloc_logger = probe_logger;
}

void aak_probe_begin(aak_probe_counts *counts) {
    pthread_once(&probe_once, probe_install);
    counts->allocations = 0;
    counts->deallocations = 0;
    pthread_setspecific(probe_key, counts);
}

void aak_probe_end(void) {
    pthread_setspecific(probe_key, NULL);
}

void aak_set_flush_denormals(bool flush) {
#if defined(__arm64__) || defined(__aarch64__)
    uint64_t fpcr = __builtin_arm_rsr64("fpcr");
    const uint64_t flush_to_zero = 1ull << 24;
    __builtin_arm_wsr64("fpcr", flush ? (fpcr | flush_to_zero) : (fpcr & ~flush_to_zero));
#elif defined(__x86_64__)
    _MM_SET_FLUSH_ZERO_MODE(flush ? _MM_FLUSH_ZERO_ON : _MM_FLUSH_ZERO_OFF);
    _MM_SET_DENORMALS_ZERO_MODE(flush ? _MM_DENORMALS_ZERO_ON : _MM_DENORMALS_ZERO_OFF);
#else
    (void)flush;
#endif
}
