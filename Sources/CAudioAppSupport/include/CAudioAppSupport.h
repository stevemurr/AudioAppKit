#ifndef C_AUDIO_APP_SUPPORT_H
#define C_AUDIO_APP_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>

/// What one probed stretch of a thread did to the heap.
typedef struct {
    int64_t allocations;
    int64_t deallocations;
} aak_probe_counts;

/// Starts counting heap activity on the calling thread into `counts`, which must outlive the
/// matching `aak_probe_end`. Probes do not nest.
void aak_probe_begin(aak_probe_counts *counts);
void aak_probe_end(void);

/// Makes the calling thread treat denormal floats as zero, or restores the default.
void aak_set_flush_denormals(bool flush);

#endif
