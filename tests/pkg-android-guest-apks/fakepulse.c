#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <android/log.h>
#include <cutils/properties.h>
#include <cutils/str_parms.h>
#include <pulse/context.h>
#include <pulse/error.h>
#include <pulse/rtclock.h>
#include <pulse/stream.h>
#include <pulse/thread-mainloop.h>
#include <pulse/timeval.h>

#include "fakepulse.h"

enum { PROPLIST = 16, PROPS = 16, REQUESTS = 256, LOGS = 8192, SCHEDS = 64 };

struct pa_proplist {
	unsigned int count;
	char *keys[PROPLIST];
	char *values[PROPLIST];
};

struct pa_operation {
	int unused;
};

struct str_parms {
	int unused;
};

struct pa_time_event {
	pa_threaded_mainloop *m;
	bool enabled;
	bool dead;
	pa_usec_t at;
	pa_time_event_cb_t cb;
	void *userdata;
	struct pa_time_event *next;
};

struct pa_defer_event {
	pa_threaded_mainloop *m;
	bool enabled;
	bool dead;
	pa_defer_event_cb_t cb;
	void *userdata;
	struct pa_defer_event *next;
};

struct pa_threaded_mainloop {
	pa_mainloop_api api;
	pthread_t thread;
	pid_t tid;
	bool started;
	bool quit;
	pthread_cond_t wake;
	pthread_cond_t cond;
	struct pa_time_event *times;
	struct pa_defer_event *defers;
};

struct pa_context {
	int refs;
	pa_threaded_mainloop *m;
	pa_context_state_t state;
	int error;
	pa_context_notify_cb_t state_cb;
	void *state_userdata;
	pa_proplist props;
	pa_usec_t ready_at;
	struct pa_context *next;
};

struct request {
	pa_usec_t at;
	size_t bytes;
};

struct pa_stream {
	int refs;
	pa_context *c;
	pa_threaded_mainloop *m;
	pa_stream_state_t state;
	pa_stream_notify_cb_t state_cb;
	void *state_userdata;
	pa_stream_request_cb_t write_cb;
	void *write_userdata;
	pa_stream_notify_cb_t started_cb;
	void *started_userdata;
	pa_stream_notify_cb_t underflow_cb;
	void *underflow_userdata;
	pa_stream_notify_cb_t latency_cb;
	void *latency_userdata;
	pa_sample_spec spec;
	pa_buffer_attr attr;
	pa_usec_t ready_at;
	pa_usec_t timing_at;
	pa_usec_t update_at;
	pa_usec_t start_at;
	pa_usec_t tick0;
	uint64_t ticks;
	bool ticking;
	bool corked;
	bool playing;
	bool underrun;
	int64_t requested;
	int64_t write_index;
	int64_t read_index;
	struct request requests[REQUESTS];
	unsigned int request_head;
	unsigned int request_count;
	bool timing_valid;
	pa_timing_info timing;
	struct pa_stream *next;
};

static pthread_mutex_t big = PTHREAD_MUTEX_INITIALIZER;
static pid_t big_owner;
static pa_threaded_mainloop *current;
static pa_context *contexts;
static pa_stream *streams;

static struct {
	bool up;
	bool silent;
	pa_usec_t connect_delay;
	pa_usec_t stream_delay;
	pa_usec_t request_delay;
	pa_usec_t start_delay;
	pa_usec_t sink_latency;
	pa_usec_t timing_interval;
	unsigned int connects;
	bool fail_stream;
	bool write_marked;
	pa_usec_t first_write;
	bool have_stream;
	pa_buffer_attr attr;
	uint32_t flags;
	pa_sample_spec spec;
	pa_proplist client;
} server;

static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static char *logs[LOGS];
static unsigned int log_count;

static pthread_mutex_t prop_lock = PTHREAD_MUTEX_INITIALIZER;
static char *prop_keys[PROPS];
static char *prop_values[PROPS];

static pthread_mutex_t sched_lock = PTHREAD_MUTEX_INITIALIZER;
static struct fake_sched scheds[SCHEDS];
static unsigned int sched_count;

static pthread_mutex_t pcm_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t pcm_open_delay;

static void die(const char *what)
{
	fprintf(stderr, "fakepulse: %s\n", what);
	abort();
}

uint64_t fake_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void big_lock(void)
{
	pthread_mutex_lock(&big);
	big_owner = gettid();
}

static void big_unlock(void)
{
	big_owner = 0;
	pthread_mutex_unlock(&big);
}

static void big_wait(pthread_cond_t *cond, pa_usec_t until)
{
	struct timespec ts = { until / 1000000, until % 1000000 * 1000 };

	big_owner = 0;
	if (until == PA_USEC_INVALID)
		pthread_cond_wait(cond, &big);
	else
		pthread_cond_timedwait(cond, &big, &ts);
	big_owner = gettid();
}

static void held(const pa_threaded_mainloop *m)
{
	if (m->started && !m->quit && big_owner != gettid())
		die("libpulse called without the mainloop lock");
}

static void kick(const pa_threaded_mainloop *m)
{
	pthread_cond_signal((pthread_cond_t *)&m->wake);
}

static size_t frame_size(const pa_sample_spec *spec)
{
	return spec->channels * 2;
}

static void props_clear(pa_proplist *p)
{
	for (unsigned int i = 0; i < p->count; i++) {
		free(p->keys[i]);
		free(p->values[i]);
	}
	p->count = 0;
}

pa_proplist *pa_proplist_new(void)
{
	return calloc(1, sizeof(pa_proplist));
}

void pa_proplist_free(pa_proplist *p)
{
	props_clear(p);
	free(p);
}

int pa_proplist_sets(pa_proplist *p, const char *key, const char *value)
{
	for (unsigned int i = 0; i < p->count; i++) {
		if (!strcmp(p->keys[i], key)) {
			free(p->values[i]);
			p->values[i] = strdup(value);
			return 0;
		}
	}
	if (p->count == PROPLIST)
		return -1;
	p->keys[p->count] = strdup(key);
	p->values[p->count++] = strdup(value);
	return 0;
}

static void props_copy(pa_proplist *dst, const pa_proplist *src)
{
	props_clear(dst);
	for (unsigned int i = 0; i < src->count; i++)
		pa_proplist_sets(dst, src->keys[i], src->values[i]);
}

static pa_time_event *time_new_at(pa_threaded_mainloop *m, pa_usec_t at, pa_time_event_cb_t cb, void *userdata)
{
	pa_time_event *e = calloc(1, sizeof(*e));

	e->m = m;
	e->enabled = at != PA_USEC_INVALID;
	e->at = at;
	e->cb = cb;
	e->userdata = userdata;
	e->next = m->times;
	m->times = e;
	kick(m);
	return e;
}

static void time_set(pa_time_event *e, pa_usec_t at)
{
	if (e->dead)
		die("restart of a freed time event");
	e->enabled = at != PA_USEC_INVALID;
	e->at = at;
	kick(e->m);
}

static pa_usec_t tv_usec(const struct timeval *tv)
{
	return tv ? (pa_usec_t)tv->tv_sec * 1000000 + tv->tv_usec : PA_USEC_INVALID;
}

static pa_time_event *api_time_new(pa_mainloop_api *a, const struct timeval *tv, pa_time_event_cb_t cb, void *userdata)
{
	held(a->userdata);
	return time_new_at(a->userdata, tv_usec(tv), cb, userdata);
}

static void api_time_restart(pa_time_event *e, const struct timeval *tv)
{
	held(e->m);
	time_set(e, tv_usec(tv));
}

static void api_time_free(pa_time_event *e)
{
	held(e->m);
	if (e->dead)
		die("a time event freed twice");
	e->dead = true;
	e->enabled = false;
}

static void api_time_set_destroy(pa_time_event *e, pa_time_event_destroy_cb_t cb)
{
}

static pa_defer_event *api_defer_new(pa_mainloop_api *a, pa_defer_event_cb_t cb, void *userdata)
{
	pa_threaded_mainloop *m = a->userdata;
	pa_defer_event *e = calloc(1, sizeof(*e));

	held(m);
	e->m = m;
	e->enabled = true;
	e->cb = cb;
	e->userdata = userdata;
	e->next = m->defers;
	m->defers = e;
	kick(m);
	return e;
}

static void api_defer_enable(pa_defer_event *e, int b)
{
	held(e->m);
	e->enabled = b;
	kick(e->m);
}

static void api_defer_free(pa_defer_event *e)
{
	held(e->m);
	e->dead = true;
	e->enabled = false;
}

static void api_defer_set_destroy(pa_defer_event *e, pa_defer_event_destroy_cb_t cb)
{
}

static void api_quit(pa_mainloop_api *a, int retval)
{
}

static void stream_unref(pa_stream *s)
{
	if (--s->refs)
		return;
	if (s->c)
		die("a linked stream was freed");
	for (pa_stream **p = &streams; *p; p = &(*p)->next) {
		if (*p == s) {
			*p = s->next;
			break;
		}
	}
	free(s);
}

static void stream_set_state(pa_stream *s, pa_stream_state_t state)
{
	if (s->state == state)
		return;
	s->refs++;
	s->state = state;
	if (s->state_cb)
		s->state_cb(s, s->state_userdata);
	stream_unref(s);
}

static void stream_unlink(pa_stream *s, pa_stream_state_t state)
{
	s->refs++;
	stream_set_state(s, state);
	s->c = NULL;
	s->state_cb = NULL;
	s->write_cb = NULL;
	s->started_cb = NULL;
	s->underflow_cb = NULL;
	s->latency_cb = NULL;
	stream_unref(s);
	stream_unref(s);
}

static void context_unref(pa_context *c)
{
	if (--c->refs)
		return;
	for (pa_stream *s = streams; s; s = s->next)
		if (s->c == c)
			die("a context with linked streams was freed");
	for (pa_context **p = &contexts; *p; p = &(*p)->next) {
		if (*p == c) {
			*p = c->next;
			break;
		}
	}
	props_clear(&c->props);
	free(c);
}

static void context_set_state(pa_context *c, pa_context_state_t state)
{
	if (c->state == state)
		return;
	c->refs++;
	c->state = state;
	if (c->state_cb)
		c->state_cb(c, c->state_userdata);
	if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
		for (;;) {
			pa_stream *s = streams;

			while (s && s->c != c)
				s = s->next;
			if (!s)
				break;
			stream_unlink(s, state == PA_CONTEXT_FAILED ? PA_STREAM_FAILED : PA_STREAM_TERMINATED);
		}
	}
	context_unref(c);
}

static void queue_request(pa_stream *s, pa_usec_t at, size_t bytes)
{
	if (s->request_count == REQUESTS)
		die("request queue full");
	s->requests[(s->request_head + s->request_count++) % REQUESTS] = (struct request){ at, bytes };
}

static pa_usec_t tick_at(const pa_stream *s)
{
	uint64_t frames = s->attr.minreq / frame_size(&s->spec);

	return s->tick0 + s->ticks * frames * 1000000 / s->spec.rate;
}

static bool consuming(const pa_stream *s)
{
	return s->c && s->state == PA_STREAM_READY && !s->corked && !server.silent;
}

static void consume(pa_stream *s, pa_usec_t now)
{
	int64_t fill = s->write_index - s->read_index;
	size_t quantum = s->attr.minreq;
	size_t take;

	if (!s->playing) {
		if (fill < (int64_t)s->attr.prebuf)
			return;
		s->playing = true;
		s->underrun = false;
		if (s->started_cb)
			s->started_cb(s, s->started_userdata);
		if (!s->c)
			return;
	}
	take = fill < (int64_t)quantum ? (size_t)fill : quantum;
	s->read_index += take;
	if (take)
		queue_request(s, now + server.request_delay, take);
	if (take < quantum) {
		s->playing = false;
		if (!s->underrun) {
			s->underrun = true;
			if (s->underflow_cb)
				s->underflow_cb(s, s->underflow_userdata);
		}
	}
}

static void timing_update(pa_stream *s, pa_usec_t now)
{
	s->timing.write_index = s->write_index;
	s->timing.read_index = s->read_index;
	s->timing.write_index_corrupt = 0;
	s->timing.read_index_corrupt = 0;
	s->timing.playing = s->playing;
	s->timing_valid = true;
	s->update_at = now + server.timing_interval;
	if (s->latency_cb)
		s->latency_cb(s, s->latency_userdata);
}

static bool server_step(pa_usec_t now)
{
	for (pa_context *c = contexts; c; c = c->next) {
		if (c->state == PA_CONTEXT_CONNECTING && now >= c->ready_at) {
			c->error = server.up ? 0 : PA_ERR_CONNECTIONREFUSED;
			context_set_state(c, server.up ? PA_CONTEXT_READY : PA_CONTEXT_FAILED);
			return true;
		}
		if (!server.up && c->state == PA_CONTEXT_READY) {
			c->error = PA_ERR_CONNECTIONTERMINATED;
			context_set_state(c, PA_CONTEXT_FAILED);
			return true;
		}
	}
	for (pa_stream *s = streams; s; s = s->next) {
		if (!s->c)
			continue;
		if (server.fail_stream && s->state == PA_STREAM_READY) {
			server.fail_stream = false;
			s->c->error = PA_ERR_KILLED;
			stream_unlink(s, PA_STREAM_FAILED);
			return true;
		}
		if (s->state == PA_STREAM_CREATING && now >= s->ready_at) {
			s->refs++;
			s->requested = s->attr.tlength;
			s->timing_at = now + 2000;
			s->update_at = s->timing_at;
			stream_set_state(s, PA_STREAM_READY);
			if (s->c && s->write_cb)
				s->write_cb(s, s->attr.tlength, s->write_userdata);
			stream_unref(s);
			return true;
		}
		if (s->state != PA_STREAM_READY)
			continue;
		if (now >= s->update_at) {
			s->refs++;
			timing_update(s, now);
			stream_unref(s);
			return true;
		}
		if (s->request_count && s->requests[s->request_head].at <= now) {
			size_t bytes = s->requests[s->request_head].bytes;

			s->request_head = (s->request_head + 1) % REQUESTS;
			s->request_count--;
			s->requested += bytes;
			if (s->write_cb)
				s->write_cb(s, bytes, s->write_userdata);
			return true;
		}
		if (!consuming(s) || now < s->start_at) {
			s->ticking = false;
			continue;
		}
		if (!s->ticking) {
			s->ticking = true;
			s->tick0 = now;
			s->ticks = 0;
		}
		if (now >= tick_at(s)) {
			s->refs++;
			consume(s, now);
			s->ticks++;
			stream_unref(s);
			return true;
		}
	}
	return false;
}

static pa_usec_t server_next(pa_usec_t now, pa_usec_t next)
{
	for (pa_context *c = contexts; c; c = c->next)
		if (c->state == PA_CONTEXT_CONNECTING && c->ready_at < next)
			next = c->ready_at;
	for (pa_stream *s = streams; s; s = s->next) {
		if (!s->c)
			continue;
		if (s->state == PA_STREAM_CREATING && s->ready_at < next)
			next = s->ready_at;
		if (s->state != PA_STREAM_READY)
			continue;
		if (s->update_at < next)
			next = s->update_at;
		if (s->request_count && s->requests[s->request_head].at < next)
			next = s->requests[s->request_head].at;
		if (!consuming(s))
			continue;
		if (now < s->start_at) {
			if (s->start_at < next)
				next = s->start_at;
		} else if (!s->ticking) {
			next = now;
		} else if (tick_at(s) < next) {
			next = tick_at(s);
		}
	}
	return next;
}

static bool run_one(pa_threaded_mainloop *m, pa_usec_t now)
{
	for (pa_defer_event *d = m->defers; d; d = d->next) {
		if (d->enabled && !d->dead) {
			d->cb(&m->api, d, d->userdata);
			return true;
		}
	}
	for (pa_time_event *t = m->times; t; t = t->next) {
		if (t->enabled && !t->dead && t->at <= now) {
			struct timeval tv = { t->at / 1000000, t->at % 1000000 };

			t->enabled = false;
			t->cb(&m->api, t, &tv, t->userdata);
			return true;
		}
	}
	return server_step(now);
}

static void reap(pa_threaded_mainloop *m)
{
	for (pa_time_event **p = &m->times; *p;) {
		pa_time_event *e = *p;

		if (e->dead) {
			*p = e->next;
			free(e);
		} else {
			p = &e->next;
		}
	}
	for (pa_defer_event **p = &m->defers; *p;) {
		pa_defer_event *e = *p;

		if (e->dead) {
			*p = e->next;
			free(e);
		} else {
			p = &e->next;
		}
	}
}

static void *loop_main(void *arg)
{
	pa_threaded_mainloop *m = arg;

	big_lock();
	m->tid = gettid();
	while (!m->quit) {
		pa_usec_t now = fake_now();
		pa_usec_t next = now + 100000;
		bool ran = run_one(m, now);

		reap(m);
		if (ran)
			continue;
		for (pa_time_event *t = m->times; t; t = t->next)
			if (t->enabled && t->at < next)
				next = t->at;
		big_wait(&m->wake, server_next(now, next));
	}
	big_unlock();
	return NULL;
}

pa_threaded_mainloop *pa_threaded_mainloop_new(void)
{
	pa_threaded_mainloop *m = calloc(1, sizeof(*m));
	pthread_condattr_t attr;

	pthread_condattr_init(&attr);
	pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
	pthread_cond_init(&m->wake, &attr);
	pthread_cond_init(&m->cond, &attr);
	pthread_condattr_destroy(&attr);
	m->api.userdata = m;
	m->api.time_new = api_time_new;
	m->api.time_restart = api_time_restart;
	m->api.time_free = api_time_free;
	m->api.time_set_destroy = api_time_set_destroy;
	m->api.defer_new = api_defer_new;
	m->api.defer_enable = api_defer_enable;
	m->api.defer_free = api_defer_free;
	m->api.defer_set_destroy = api_defer_set_destroy;
	m->api.quit = api_quit;
	big_lock();
	if (current)
		die("a second mainloop");
	current = m;
	big_unlock();
	return m;
}

void pa_threaded_mainloop_set_name(pa_threaded_mainloop *m, const char *name)
{
}

pa_mainloop_api *pa_threaded_mainloop_get_api(pa_threaded_mainloop *m)
{
	return &m->api;
}

int pa_threaded_mainloop_start(pa_threaded_mainloop *m)
{
	m->started = true;
	return pthread_create(&m->thread, NULL, loop_main, m) ? -1 : 0;
}

void pa_threaded_mainloop_stop(pa_threaded_mainloop *m)
{
	if (gettid() == m->tid)
		die("stop from the loop thread");
	big_lock();
	m->quit = true;
	kick(m);
	big_unlock();
	pthread_join(m->thread, NULL);
}

void pa_threaded_mainloop_free(pa_threaded_mainloop *m)
{
	if (m->started && !m->quit)
		die("free of a running mainloop");
	big_lock();
	for (pa_time_event *t = m->times; t; t = t->next)
		if (!t->dead)
			die("a time event outlived its mainloop");
	for (pa_defer_event *d = m->defers; d; d = d->next)
		if (!d->dead)
			die("a defer event outlived its mainloop");
	if (contexts || streams)
		die("a context or stream outlived its mainloop");
	m->quit = true;
	reap(m);
	current = NULL;
	big_unlock();
	pthread_cond_destroy(&m->wake);
	pthread_cond_destroy(&m->cond);
	free(m);
}

void pa_threaded_mainloop_lock(pa_threaded_mainloop *m)
{
	if (gettid() == m->tid)
		die("lock from the loop thread");
	big_lock();
}

void pa_threaded_mainloop_unlock(pa_threaded_mainloop *m)
{
	held(m);
	big_unlock();
}

void pa_threaded_mainloop_wait(pa_threaded_mainloop *m)
{
	held(m);
	if (gettid() == m->tid)
		die("wait in the loop thread");
	big_wait(&m->cond, PA_USEC_INVALID);
}

void pa_threaded_mainloop_signal(pa_threaded_mainloop *m, int wait_for_accept)
{
	held(m);
	pthread_cond_broadcast(&m->cond);
}

pa_context *pa_context_new_with_proplist(pa_mainloop_api *api, const char *name, const pa_proplist *props)
{
	pa_threaded_mainloop *m = api->userdata;
	pa_context *c = calloc(1, sizeof(*c));

	held(m);
	c->refs = 1;
	c->m = m;
	c->state = PA_CONTEXT_UNCONNECTED;
	if (props)
		props_copy(&c->props, props);
	props_copy(&server.client, &c->props);
	c->next = contexts;
	contexts = c;
	return c;
}

void pa_context_set_state_callback(pa_context *c, pa_context_notify_cb_t cb, void *userdata)
{
	held(c->m);
	c->state_cb = cb;
	c->state_userdata = userdata;
}

int pa_context_connect(pa_context *c, const char *name, pa_context_flags_t flags, const pa_spawn_api *api)
{
	held(c->m);
	if (c->state != PA_CONTEXT_UNCONNECTED)
		die("connect of a used context");
	if (!(flags & PA_CONTEXT_NOAUTOSPAWN))
		die("connect may autospawn");
	server.connects++;
	c->ready_at = fake_now() + server.connect_delay;
	context_set_state(c, PA_CONTEXT_CONNECTING);
	if (!server.up) {
		c->error = PA_ERR_CONNECTIONREFUSED;
		context_set_state(c, PA_CONTEXT_FAILED);
		return -PA_ERR_CONNECTIONREFUSED;
	}
	kick(c->m);
	return 0;
}

pa_context_state_t pa_context_get_state(const pa_context *c)
{
	held(c->m);
	return c->state;
}

int pa_context_errno(const pa_context *c)
{
	held(c->m);
	return c->error;
}

void pa_context_disconnect(pa_context *c)
{
	held(c->m);
	if (c->state == PA_CONTEXT_CONNECTING || c->state == PA_CONTEXT_READY)
		context_set_state(c, PA_CONTEXT_TERMINATED);
}

void pa_context_unref(pa_context *c)
{
	held(c->m);
	context_unref(c);
}

pa_time_event *pa_context_rttime_new(const pa_context *c, pa_usec_t usec, pa_time_event_cb_t cb, void *userdata)
{
	if (!c)
		die("rttime_new without a context");
	held(c->m);
	return time_new_at(c->m, usec, cb, userdata);
}

void pa_context_rttime_restart(const pa_context *c, pa_time_event *e, pa_usec_t usec)
{
	if (!c)
		die("rttime_restart without a context");
	held(c->m);
	time_set(e, usec);
}

pa_stream *pa_stream_new(pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map)
{
	pa_stream *s = calloc(1, sizeof(*s));

	held(c->m);
	s->refs = 2;
	s->c = c;
	s->m = c->m;
	s->spec = *ss;
	s->state = PA_STREAM_UNCONNECTED;
	s->corked = true;
	s->next = streams;
	streams = s;
	return s;
}

static bool dead(const pa_stream *s)
{
	return s->state == PA_STREAM_FAILED || s->state == PA_STREAM_TERMINATED;
}

void pa_stream_set_state_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata)
{
	held(s->m);
	if (dead(s))
		return;
	s->state_cb = cb;
	s->state_userdata = userdata;
}

void pa_stream_set_write_callback(pa_stream *s, pa_stream_request_cb_t cb, void *userdata)
{
	held(s->m);
	if (dead(s))
		return;
	s->write_cb = cb;
	s->write_userdata = userdata;
}

void pa_stream_set_started_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata)
{
	held(s->m);
	if (dead(s))
		return;
	s->started_cb = cb;
	s->started_userdata = userdata;
}

void pa_stream_set_underflow_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata)
{
	held(s->m);
	if (dead(s))
		return;
	s->underflow_cb = cb;
	s->underflow_userdata = userdata;
}

void pa_stream_set_latency_update_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata)
{
	held(s->m);
	if (dead(s))
		return;
	s->latency_cb = cb;
	s->latency_userdata = userdata;
}

int pa_stream_connect_playback(pa_stream *s, const char *dev, const pa_buffer_attr *attr, pa_stream_flags_t flags,
			       const pa_cvolume *volume, pa_stream *sync)
{
	held(s->m);
	if (!s->c || s->c->state != PA_CONTEXT_READY || s->state != PA_STREAM_UNCONNECTED)
		return -PA_ERR_BADSTATE;
	s->attr = *attr;
	s->corked = flags & PA_STREAM_START_CORKED;
	server.have_stream = true;
	server.attr = *attr;
	server.flags = flags;
	server.spec = s->spec;
	s->ready_at = fake_now() + server.stream_delay;
	stream_set_state(s, PA_STREAM_CREATING);
	kick(s->m);
	return 0;
}

pa_stream_state_t pa_stream_get_state(const pa_stream *s)
{
	held(s->m);
	return s->state;
}

pa_context *pa_stream_get_context(const pa_stream *s)
{
	held(s->m);
	return s->c;
}

size_t pa_stream_writable_size(const pa_stream *s)
{
	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY)
		return (size_t)-1;
	return s->requested > 0 ? (size_t)s->requested : 0;
}

int pa_stream_write(pa_stream *s, const void *data, size_t nbytes, pa_free_cb_t free_cb, int64_t offset,
		    pa_seek_mode_t seek)
{
	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY)
		return -PA_ERR_BADSTATE;
	if (nbytes % frame_size(&s->spec) || offset || seek != PA_SEEK_RELATIVE || free_cb)
		die("a write the HAL does not make");
	s->requested -= nbytes;
	s->write_index += nbytes;
	if (s->timing_valid && !s->timing.write_index_corrupt)
		s->timing.write_index += nbytes;
	if (server.write_marked && !server.first_write)
		server.first_write = fake_now();
	kick(s->m);
	return 0;
}

static pa_operation *operation(void)
{
	return calloc(1, sizeof(pa_operation));
}

pa_operation *pa_stream_cork(pa_stream *s, int b, pa_stream_success_cb_t cb, void *userdata)
{
	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY)
		return NULL;
	s->corked = b;
	s->ticking = false;
	if (!b) {
		s->start_at = fake_now() + server.start_delay;
		s->playing = false;
		s->underrun = false;
	}
	kick(s->m);
	return operation();
}

pa_operation *pa_stream_flush(pa_stream *s, pa_stream_success_cb_t cb, void *userdata)
{
	int64_t flushed;

	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY)
		return NULL;
	flushed = s->write_index - s->read_index;
	s->read_index = s->write_index;
	s->playing = false;
	s->timing_at = fake_now() + 2000;
	s->update_at = s->timing_at;
	s->timing.write_index_corrupt = 1;
	if (flushed)
		queue_request(s, fake_now(), flushed);
	kick(s->m);
	return operation();
}

int pa_stream_get_latency(pa_stream *s, pa_usec_t *usec, int *negative)
{
	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY)
		return -PA_ERR_BADSTATE;
	if (fake_now() < s->timing_at)
		return -PA_ERR_NODATA;
	*usec = (s->write_index - s->read_index) / frame_size(&s->spec) * 1000000 / s->spec.rate + server.sink_latency;
	if (negative)
		*negative = 0;
	return 0;
}

const pa_timing_info *pa_stream_get_timing_info(pa_stream *s)
{
	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY || !s->timing_valid)
		return NULL;
	return &s->timing;
}

int pa_stream_disconnect(pa_stream *s)
{
	held(s->m);
	if (!s->c || s->state != PA_STREAM_READY)
		return -PA_ERR_BADSTATE;
	stream_unlink(s, PA_STREAM_TERMINATED);
	return 0;
}

void pa_stream_unref(pa_stream *s)
{
	held(s->m);
	stream_unref(s);
}

void pa_operation_unref(pa_operation *o)
{
	free(o);
}

pa_channel_map *pa_channel_map_init_stereo(pa_channel_map *m)
{
	memset(m, 0, sizeof(*m));
	m->channels = 2;
	m->map[0] = PA_CHANNEL_POSITION_FRONT_LEFT;
	m->map[1] = PA_CHANNEL_POSITION_FRONT_RIGHT;
	return m;
}

pa_usec_t pa_rtclock_now(void)
{
	return fake_now();
}

const char *pa_strerror(int error)
{
	switch (error) {
	case PA_ERR_CONNECTIONREFUSED:
		return "Connection refused";
	case PA_ERR_CONNECTIONTERMINATED:
		return "Connection terminated";
	default:
		return "Error";
	}
}

void fake_reset(void)
{
	big_lock();
	if (current || contexts || streams)
		die("reset with a mainloop, context or stream alive");
	props_clear(&server.client);
	memset(&server, 0, sizeof(server));
	server.up = true;
	server.connect_delay = 1000;
	server.stream_delay = 1000;
	server.timing_interval = 10000;
	big_unlock();
	pthread_mutex_lock(&log_lock);
	for (unsigned int i = 0; i < log_count; i++)
		free(logs[i]);
	log_count = 0;
	pthread_mutex_unlock(&log_lock);
	pthread_mutex_lock(&prop_lock);
	for (unsigned int i = 0; i < PROPS; i++) {
		free(prop_keys[i]);
		free(prop_values[i]);
		prop_keys[i] = prop_values[i] = NULL;
	}
	pthread_mutex_unlock(&prop_lock);
	pthread_mutex_lock(&sched_lock);
	sched_count = 0;
	pthread_mutex_unlock(&sched_lock);
	pthread_mutex_lock(&pcm_lock);
	pcm_open_delay = 0;
	pthread_mutex_unlock(&pcm_lock);
}

static void server_set(void (*set)(void *), void *arg)
{
	big_lock();
	set(arg);
	if (current)
		kick(current);
	big_unlock();
}

static void set_up(void *arg)
{
	server.up = *(bool *)arg;
}

static void set_silent(void *arg)
{
	server.silent = *(bool *)arg;
}

static void set_request_delay(void *arg)
{
	server.request_delay = *(uint64_t *)arg;
}

static void set_start_delay(void *arg)
{
	server.start_delay = *(uint64_t *)arg;
}

static void set_sink_latency(void *arg)
{
	server.sink_latency = *(uint64_t *)arg;
}

static void set_timing_interval(void *arg)
{
	server.timing_interval = *(uint64_t *)arg;
}

static void set_stream_delay(void *arg)
{
	server.stream_delay = *(uint64_t *)arg;
}

static void set_connect_delay(void *arg)
{
	server.connect_delay = *(uint64_t *)arg;
}

static void fail_stream(void *arg)
{
	server.fail_stream = true;
}

static void mark_write(void *arg)
{
	server.write_marked = true;
	server.first_write = 0;
}

void fake_set_up(bool up)
{
	server_set(set_up, &up);
}

void fake_set_silent(bool silent)
{
	server_set(set_silent, &silent);
}

void fake_set_request_delay(uint64_t usec)
{
	server_set(set_request_delay, &usec);
}

void fake_set_start_delay(uint64_t usec)
{
	server_set(set_start_delay, &usec);
}

void fake_set_sink_latency(uint64_t usec)
{
	server_set(set_sink_latency, &usec);
}

void fake_set_timing_interval(uint64_t usec)
{
	server_set(set_timing_interval, &usec);
}

void fake_set_stream_delay(uint64_t usec)
{
	server_set(set_stream_delay, &usec);
}

void fake_set_connect_delay(uint64_t usec)
{
	server_set(set_connect_delay, &usec);
}

void fake_set_pcm_open_delay(uint64_t usec)
{
	pthread_mutex_lock(&pcm_lock);
	pcm_open_delay = usec;
	pthread_mutex_unlock(&pcm_lock);
}

void fake_fail_stream(void)
{
	server_set(fail_stream, NULL);
}

void fake_mark_write(void)
{
	server_set(mark_write, NULL);
}

uint64_t fake_first_write(void)
{
	uint64_t t;

	big_lock();
	t = server.first_write;
	big_unlock();
	return t;
}

unsigned int fake_streams(void)
{
	unsigned int n = 0;

	big_lock();
	for (pa_stream *s = streams; s; s = s->next)
		n++;
	big_unlock();
	return n;
}

bool fake_played(int64_t *frames, uint64_t *at)
{
	bool found = false;

	big_lock();
	*at = fake_now();
	for (pa_stream *s = streams; s && !found; s = s->next) {
		if (s->c && s->state == PA_STREAM_READY) {
			*frames = s->read_index / (int64_t)frame_size(&s->spec) -
				  (int64_t)(server.sink_latency * s->spec.rate / 1000000);
			found = true;
		}
	}
	big_unlock();
	return found;
}

unsigned int fake_connects(void)
{
	unsigned int n;

	big_lock();
	n = server.connects;
	big_unlock();
	return n;
}

bool fake_last_stream(pa_buffer_attr *attr, uint32_t *flags, pa_sample_spec *spec)
{
	bool have;

	big_lock();
	have = server.have_stream;
	*attr = server.attr;
	*flags = server.flags;
	*spec = server.spec;
	big_unlock();
	return have;
}

bool fake_client_prop(const char *key, char *value, size_t len)
{
	bool found = false;

	big_lock();
	for (unsigned int i = 0; i < server.client.count; i++) {
		if (!strcmp(server.client.keys[i], key)) {
			snprintf(value, len, "%s", server.client.values[i]);
			found = true;
		}
	}
	big_unlock();
	return found;
}

pid_t fake_loop_tid(void)
{
	pid_t tid;

	big_lock();
	tid = current ? current->tid : 0;
	big_unlock();
	return tid;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
	char line[1024];
	va_list args;

	va_start(args, fmt);
	vsnprintf(line, sizeof(line), fmt, args);
	va_end(args);
	pthread_mutex_lock(&log_lock);
	if (log_count < LOGS)
		logs[log_count++] = strdup(line);
	pthread_mutex_unlock(&log_lock);
	if (getenv("AUDIOTEST_LOG"))
		fprintf(stderr, "log %d %s: %s\n", prio, tag, line);
	return 1;
}

void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
	va_list args;

	fprintf(stderr, "assert %s: ", tag);
	if (fmt) {
		va_start(args, fmt);
		vfprintf(stderr, fmt, args);
		va_end(args);
	}
	fputc('\n', stderr);
	abort();
}

unsigned int fake_log_mark(void)
{
	unsigned int n;

	pthread_mutex_lock(&log_lock);
	n = log_count;
	pthread_mutex_unlock(&log_lock);
	return n;
}

unsigned int fake_log_since(unsigned int mark)
{
	return fake_log_mark() - mark;
}

unsigned int fake_log_count(const char *needle)
{
	unsigned int n = 0;

	pthread_mutex_lock(&log_lock);
	for (unsigned int i = 0; i < log_count; i++)
		if (strstr(logs[i], needle))
			n++;
	pthread_mutex_unlock(&log_lock);
	return n;
}

bool fake_log_line(const char *needle, unsigned int nth, char *line, size_t len)
{
	bool found = false;

	pthread_mutex_lock(&log_lock);
	for (unsigned int i = 0; i < log_count && !found; i++) {
		if (strstr(logs[i], needle) && !nth--) {
			snprintf(line, len, "%s", logs[i]);
			found = true;
		}
	}
	pthread_mutex_unlock(&log_lock);
	return found;
}

void fake_set_prop(const char *key, const char *value)
{
	pthread_mutex_lock(&prop_lock);
	for (unsigned int i = 0; i < PROPS; i++) {
		if (prop_keys[i] && !strcmp(prop_keys[i], key)) {
			free(prop_keys[i]);
			free(prop_values[i]);
			prop_keys[i] = prop_values[i] = NULL;
		}
	}
	for (unsigned int i = 0; value && i < PROPS; i++) {
		if (!prop_keys[i]) {
			prop_keys[i] = strdup(key);
			prop_values[i] = strdup(value);
			break;
		}
	}
	pthread_mutex_unlock(&prop_lock);
}

int property_get(const char *key, char *value, const char *default_value)
{
	const char *found = default_value ? default_value : "";

	pthread_mutex_lock(&prop_lock);
	for (unsigned int i = 0; i < PROPS; i++)
		if (prop_keys[i] && !strcmp(prop_keys[i], key))
			found = prop_values[i];
	snprintf(value, PROPERTY_VALUE_MAX, "%s", found);
	pthread_mutex_unlock(&prop_lock);
	return strlen(value);
}

int8_t property_get_bool(const char *key, int8_t default_value)
{
	char value[PROPERTY_VALUE_MAX];

	property_get(key, value, "");
	if (!strcmp(value, "1") || !strcmp(value, "y") || !strcmp(value, "yes") || !strcmp(value, "on") ||
	    !strcmp(value, "true"))
		return 1;
	if (!strcmp(value, "0") || !strcmp(value, "n") || !strcmp(value, "no") || !strcmp(value, "off") ||
	    !strcmp(value, "false"))
		return 0;
	return default_value;
}

struct str_parms *str_parms_create_str(const char *string)
{
	return calloc(1, sizeof(struct str_parms));
}

void str_parms_destroy(struct str_parms *parms)
{
	free(parms);
}

int str_parms_get_str(struct str_parms *parms, const char *key, char *value, int len)
{
	return -ENOENT;
}

int sched_setscheduler(pid_t pid, int policy, const struct sched_param *param)
{
	pthread_mutex_lock(&sched_lock);
	if (sched_count < SCHEDS)
		scheds[sched_count++] = (struct fake_sched){ pid ? pid : gettid(), policy, param->sched_priority };
	pthread_mutex_unlock(&sched_lock);
	return 0;
}

unsigned int fake_sched_calls(struct fake_sched *out, unsigned int max)
{
	unsigned int n;

	pthread_mutex_lock(&sched_lock);
	n = sched_count < max ? sched_count : max;
	memcpy(out, scheds, n * sizeof(*out));
	pthread_mutex_unlock(&sched_lock);
	return n;
}

int snd_pcm_open(snd_pcm_t **pcm, const char *name, snd_pcm_stream_t stream, int mode)
{
	static int handle;
	uint64_t delay;

	pthread_mutex_lock(&pcm_lock);
	delay = pcm_open_delay;
	pthread_mutex_unlock(&pcm_lock);
	if (!delay) {
		*pcm = NULL;
		return -ENOENT;
	}
	usleep(delay);
	*pcm = (snd_pcm_t *)&handle;
	return 0;
}

int snd_pcm_close(snd_pcm_t *pcm)
{
	return 0;
}

size_t snd_pcm_hw_params_sizeof(void)
{
	return 64;
}

int snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params)
{
	return -ENODEV;
}

int snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_access_t access)
{
	return -ENODEV;
}

int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_format_t format)
{
	return -ENODEV;
}

int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir)
{
	return -ENODEV;
}

int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val)
{
	return -ENODEV;
}

int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params)
{
	return -ENODEV;
}

int snd_pcm_prepare(snd_pcm_t *pcm)
{
	return -ENODEV;
}

snd_pcm_state_t snd_pcm_state(snd_pcm_t *pcm)
{
	return SND_PCM_STATE_DISCONNECTED;
}

snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *pcm, void *buffer, snd_pcm_uframes_t size)
{
	return -ENODEV;
}
