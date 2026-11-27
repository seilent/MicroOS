#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#include <pulse/def.h>
#include <pulse/sample.h>

struct fake_sched {
	pid_t tid;
	int policy;
	int priority;
};

uint64_t fake_now(void);
void fake_reset(void);
void fake_set_up(bool up);
void fake_set_silent(bool silent);
void fake_set_request_delay(uint64_t usec);
void fake_set_start_delay(uint64_t usec);
void fake_set_sink_latency(uint64_t usec);
void fake_set_timing_interval(uint64_t usec);
void fake_set_stream_delay(uint64_t usec);
void fake_set_connect_delay(uint64_t usec);
void fake_set_pcm_open_delay(uint64_t usec);
void fake_fail_stream(void);
unsigned int fake_connects(void);
void fake_mark_write(void);
uint64_t fake_first_write(void);
unsigned int fake_streams(void);
bool fake_played(int64_t *frames, uint64_t *at);
bool fake_last_stream(pa_buffer_attr *attr, uint32_t *flags, pa_sample_spec *spec);
bool fake_client_prop(const char *key, char *value, size_t len);
pid_t fake_loop_tid(void);
void fake_set_prop(const char *key, const char *value);
unsigned int fake_log_count(const char *needle);
bool fake_log_line(const char *needle, unsigned int nth, char *line, size_t len);
unsigned int fake_log_since(unsigned int mark);
unsigned int fake_log_mark(void);
unsigned int fake_sched_calls(struct fake_sched *out, unsigned int max);
