#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <hardware/audio.h>
#include <hardware/hardware.h>
#include <pulse/def.h>

#include "fakepulse.h"

enum { RECORDS = 16384, RATE = 48000, FRAME = 4 };

#define PERIOD_PROP "vendor.microos.audio.period_frames"
#define DEBUG_PROP "vendor.microos.audio.debug"
#define START_LINE "pulse stream: ready "

extern struct audio_module HAL_MODULE_INFO_SYM;

struct stats {
	unsigned int period;
	unsigned int underflows;
	unsigned int stalls;
	uint64_t dropped;
	unsigned int reconnects;
	int64_t fill;
	uint64_t latency;
	uint64_t written;
	uint64_t presented;
};

struct writer {
	pthread_t thread;
	_Atomic(struct audio_stream_out *) out;
	atomic_bool run;
	atomic_bool pause;
	atomic_uint_fast64_t handed;
	pthread_mutex_t gate;
	size_t frames;
	pid_t tid;
	unsigned int count;
	uint64_t begin[RECORDS];
	uint64_t end[RECORDS];
};

struct reader {
	pthread_t thread;
	atomic_bool run;
	struct audio_stream_out *out;
	struct writer *w;
	unsigned int reads;
	unsigned int decreases;
	unsigned int ahead;
	unsigned int backwards;
	uint64_t longest;
};

struct capture {
	struct audio_stream_in *in;
	uint64_t begin;
	uint64_t end;
};

struct start {
	bool up;
	uint64_t connect;
	uint64_t create;
	uint64_t wait;
	uint64_t dropped;
};

static const char *current;
static int failures;
static int case_failures;
static struct writer w;

static void expect(bool ok, const char *fmt, ...)
{
	va_list args;

	if (ok)
		return;
	failures++;
	case_failures++;
	printf("FAIL %s: ", current);
	va_start(args, fmt);
	vprintf(fmt, args);
	va_end(args);
	putchar('\n');
}

static void begin(const char *name)
{
	current = name;
	case_failures = 0;
	fake_reset();
}

static void end(void)
{
	if (!case_failures)
		printf("ok %s\n", current);
}

static uint64_t period_usec(unsigned int frames)
{
	return (uint64_t)frames * 1000000 / RATE;
}

static void sleep_ms(unsigned int ms)
{
	struct timespec ts = { ms / 1000, ms % 1000 * 1000000L };

	while (nanosleep(&ts, &ts))
		;
}

static audio_hw_device_t *dev_open(void)
{
	hw_device_t *device = NULL;
	int ret = HAL_MODULE_INFO_SYM.common.methods->open(&HAL_MODULE_INFO_SYM.common, AUDIO_HARDWARE_INTERFACE,
							    &device);

	if (ret || !device) {
		printf("FAIL %s: adev_open: %d\n", current, ret);
		exit(1);
	}
	return (audio_hw_device_t *)device;
}

static struct audio_stream_out *out_open(audio_hw_device_t *dev, int *ret)
{
	struct audio_config config = {
		.sample_rate = RATE,
		.channel_mask = AUDIO_CHANNEL_OUT_STEREO,
		.format = AUDIO_FORMAT_PCM_16_BIT,
	};
	struct audio_stream_out *out = NULL;

	*ret = dev->open_output_stream(dev, 0, AUDIO_DEVICE_OUT_SPEAKER, AUDIO_OUTPUT_FLAG_PRIMARY, &config, &out, "");
	return out;
}

static struct stats dump(struct audio_stream_out *out)
{
	struct stats st;
	char buf[512];
	int fds[2];
	ssize_t n;

	memset(&st, 0, sizeof(st));
	if (pipe(fds))
		abort();
	out->common.dump(&out->common, fds[1]);
	close(fds[1]);
	n = read(fds[0], buf, sizeof(buf) - 1);
	close(fds[0]);
	buf[n > 0 ? n : 0] = 0;
	expect(sscanf(buf, "MicroOS pulse output: period=%u underflows=%u stalls=%u dropped=%" SCNu64
		      " reconnects=%u fill=%" SCNd64 " latency_us=%" SCNu64 " written=%" SCNu64 " presented=%" SCNu64,
		      &st.period, &st.underflows, &st.stalls, &st.dropped, &st.reconnects, &st.fill, &st.latency,
		      &st.written, &st.presented) == 9,
	       "dump: %s", buf);
	return st;
}

static void *writer_main(void *arg)
{
	struct writer *wr = arg;
	static int16_t buf[1024 * 2];

	wr->tid = gettid();
	while (atomic_load(&wr->run)) {
		struct audio_stream_out *out;
		uint64_t t0, t1;

		if (atomic_load(&wr->pause)) {
			usleep(200);
			continue;
		}
		pthread_mutex_lock(&wr->gate);
		if (atomic_load(&wr->pause)) {
			pthread_mutex_unlock(&wr->gate);
			continue;
		}
		out = atomic_load(&wr->out);
		t0 = fake_now();
		atomic_fetch_add(&wr->handed, wr->frames);
		out->write(out, buf, wr->frames * FRAME);
		t1 = fake_now();
		if (wr->count < RECORDS) {
			wr->begin[wr->count] = t0;
			wr->end[wr->count++] = t1;
		}
		pthread_mutex_unlock(&wr->gate);
	}
	return NULL;
}

static void writer_start(struct audio_stream_out *out, size_t frames)
{
	memset(&w, 0, sizeof(w));
	pthread_mutex_init(&w.gate, NULL);
	atomic_store(&w.out, out);
	atomic_store(&w.run, true);
	w.frames = frames;
	pthread_create(&w.thread, NULL, writer_main, &w);
}

static void writer_stop(void)
{
	atomic_store(&w.run, false);
	pthread_join(w.thread, NULL);
}

static void writer_hold(void)
{
	atomic_store(&w.pause, true);
	pthread_mutex_lock(&w.gate);
}

static void writer_release(void)
{
	pthread_mutex_unlock(&w.gate);
	atomic_store(&w.pause, false);
}

static unsigned int writes_between(uint64_t from, uint64_t to)
{
	unsigned int n = 0;

	for (unsigned int i = 0; i < w.count; i++)
		if (w.begin[i] >= from && w.begin[i] < to)
			n++;
	return n;
}

static uint64_t longest_write(uint64_t from, uint64_t to)
{
	uint64_t longest = 0;

	for (unsigned int i = 0; i < w.count; i++)
		if (w.begin[i] >= from && w.end[i] <= to && w.end[i] - w.begin[i] > longest)
			longest = w.end[i] - w.begin[i];
	return longest;
}

static uint64_t shortest_write(uint64_t from, uint64_t to)
{
	uint64_t shortest = UINT64_MAX;

	for (unsigned int i = 0; i < w.count; i++)
		if (w.begin[i] >= from && w.end[i] <= to && w.end[i] - w.begin[i] < shortest)
			shortest = w.end[i] - w.begin[i];
	return shortest;
}

static void *reader_main(void *arg)
{
	struct reader *r = arg;
	struct timespec last_ts = { 0, 0 };
	uint64_t last = 0;
	bool have = false;

	while (atomic_load(&r->run)) {
		struct timespec ts;
		uint64_t frames, t0, t1, handed;
		int ret;

		t0 = fake_now();
		ret = r->out->get_presentation_position(r->out, &frames, &ts);
		t1 = fake_now();
		handed = atomic_load(&r->w->handed);
		if (t1 - t0 > r->longest)
			r->longest = t1 - t0;
		r->reads++;
		if (!ret) {
			if (have && frames < last)
				r->decreases++;
			if (have && (ts.tv_sec < last_ts.tv_sec ||
				     (ts.tv_sec == last_ts.tv_sec && ts.tv_nsec < last_ts.tv_nsec)))
				r->backwards++;
			if (frames > handed)
				r->ahead++;
			last = frames;
			last_ts = ts;
			have = true;
		}
		usleep(500);
	}
	return NULL;
}

static int64_t position_error(struct audio_stream_out *out, unsigned int ms, unsigned int *samples)
{
	uint64_t until = fake_now() + ms * 1000ULL;
	int64_t worst = 0;

	*samples = 0;
	while (fake_now() < until) {
		struct timespec ts;
		uint64_t frames, at;
		int64_t played, e;

		if (!out->get_presentation_position(out, &frames, &ts) && fake_played(&played, &at)) {
			e = (int64_t)frames - played +
			    ((int64_t)at - ts.tv_sec * 1000000LL - ts.tv_nsec / 1000) * RATE / 1000000;
			if (llabs(e) > llabs(worst))
				worst = e;
			(*samples)++;
		}
		sleep_ms(1);
	}
	return worst;
}

static bool start_line(unsigned int nth, struct start *st)
{
	char line[256];

	memset(st, 0, sizeof(*st));
	if (!fake_log_line(START_LINE, nth, line, sizeof(line)))
		return false;
	st->up = !strncmp(line, START_LINE "context=up ", strlen(START_LINE "context=up "));
	if (st->up)
		return sscanf(line, START_LINE "context=up create_us=%" SCNu64 " first_wait_us=%" SCNu64
			      " first_dropped=%" SCNu64, &st->create, &st->wait, &st->dropped) == 3;
	return sscanf(line, START_LINE "connect_us=%" SCNu64 " create_us=%" SCNu64 " first_wait_us=%" SCNu64
		      " first_dropped=%" SCNu64, &st->connect, &st->create, &st->wait, &st->dropped) == 4;
}

static void *capture_main(void *arg)
{
	struct capture *c = arg;
	static int32_t buf[320 * 2];

	c->begin = fake_now();
	c->in->read(c->in, buf, sizeof(buf));
	c->end = fake_now();
	return NULL;
}

static void case_attrs(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	pa_buffer_attr attr;
	pa_sample_spec spec;
	uint32_t flags;
	struct stats st;
	char value[64];
	int ret;

	begin("attrs and client props");
	dev = dev_open();
	out = out_open(dev, &ret);
	expect(!ret && out, "open_output_stream: %d", ret);
	writer_start(out, 256);
	sleep_ms(100);
	writer_stop();
	expect(fake_last_stream(&attr, &flags, &spec), "no stream was connected");
	expect(attr.maxlength == UINT32_MAX && attr.tlength == 3 * 256 * FRAME && attr.prebuf == 256 * FRAME &&
	       attr.minreq == 256 * FRAME, "attrs maxlength %u tlength %u prebuf %u minreq %u", attr.maxlength,
	       attr.tlength, attr.prebuf, attr.minreq);
	expect(flags == (PA_STREAM_INTERPOLATE_TIMING | PA_STREAM_AUTO_TIMING_UPDATE | PA_STREAM_EARLY_REQUESTS |
			 PA_STREAM_START_CORKED), "flags %#x", flags);
	expect(spec.format == PA_SAMPLE_S16LE && spec.rate == RATE && spec.channels == 2, "sample spec %d %u %u",
	       spec.format, spec.rate, spec.channels);
	expect(fake_client_prop("pulse.min.req", value, sizeof(value)) && !strcmp(value, "256/48000"),
	       "pulse.min.req %s", value);
	expect(fake_client_prop("pulse.min.quantum", value, sizeof(value)) && !strcmp(value, "256/48000"),
	       "pulse.min.quantum %s", value);
	st = dump(out);
	expect(st.written == atomic_load(&w.handed), "written %" PRIu64 " of %" PRIu64 " handed", st.written,
	       (uint64_t)atomic_load(&w.handed));
	expect(st.dropped == 0, "dropped %" PRIu64 " frames at the start", st.dropped);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_period(void)
{
	static const struct {
		const char *prop;
		unsigned int frames;
		uint32_t latency;
	} cases[] = { { NULL, 256, 16 }, { "256", 256, 16 }, { "128", 128, 8 }, { "64", 64, 4 } };
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	pa_buffer_attr attr;
	pa_sample_spec spec;
	uint32_t flags;
	char value[64], want[64];
	int ret;

	for (unsigned int i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		begin(cases[i].prop ? "period prop set" : "period prop absent");
		if (cases[i].prop)
			fake_set_prop(PERIOD_PROP, cases[i].prop);
		dev = dev_open();
		out = out_open(dev, &ret);
		expect(!ret && out, "%s: open_output_stream: %d", cases[i].prop, ret);
		if (!out) {
			dev->common.close(&dev->common);
			continue;
		}
		expect(out->common.get_buffer_size(&out->common) == cases[i].frames * FRAME, "%s: buffer %zu bytes",
		       cases[i].prop, out->common.get_buffer_size(&out->common));
		expect(out->get_latency(out) == cases[i].latency, "%s: latency %u ms", cases[i].prop,
		       out->get_latency(out));
		writer_start(out, cases[i].frames);
		sleep_ms(60);
		writer_stop();
		expect(fake_last_stream(&attr, &flags, &spec) && attr.tlength == 3 * cases[i].frames * FRAME &&
		       attr.minreq == cases[i].frames * FRAME && attr.prebuf == cases[i].frames * FRAME,
		       "%s: attrs tlength %u minreq %u prebuf %u", cases[i].prop, attr.tlength, attr.minreq,
		       attr.prebuf);
		snprintf(want, sizeof(want), "%u/48000", cases[i].frames);
		expect(fake_client_prop("pulse.min.req", value, sizeof(value)) && !strcmp(value, want),
		       "%s: pulse.min.req %s", cases[i].prop, value);
		expect(fake_client_prop("pulse.min.quantum", value, sizeof(value)) && !strcmp(value, want),
		       "%s: pulse.min.quantum %s", cases[i].prop, value);
		dev->close_output_stream(dev, out);
		dev->common.close(&dev->common);
		end();
	}

	begin("period prop refused");
	fake_set_prop(PERIOD_PROP, "96");
	dev = dev_open();
	out = out_open(dev, &ret);
	expect(ret && !out, "96 opened: %d", ret);
	expect(fake_log_count(PERIOD_PROP "=96") == 1, "%u error lines for 96", fake_log_count(PERIOD_PROP "=96"));
	if (out)
		dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_late_request(void)
{
	audio_hw_device_t *dev = NULL;
	struct audio_stream_out *out;
	struct stats a, b;
	uint64_t t0, t1;
	unsigned int n, want;
	int ret;

	begin("a request 2 P late loses nothing");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(100);
	a = dump(out);
	fake_set_request_delay(2 * period_usec(256));
	t0 = fake_now();
	sleep_ms(1000);
	t1 = fake_now();
	b = dump(out);
	writer_stop();
	expect(b.dropped == a.dropped, "dropped %" PRIu64 " frames", b.dropped - a.dropped);
	expect(b.stalls == a.stalls, "%u stalls", b.stalls - a.stalls);
	n = writes_between(t0 + 100000, t1);
	want = (t1 - t0 - 100000) / period_usec(256);
	expect(n + 10 >= want && n <= want + 10, "%u writes in a window of %u periods", n, want);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_silent(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct stats a, b;
	uint64_t t0, t1, longest;
	unsigned int n, want;
	int ret;

	begin("the server silent 1 s");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(300);
	a = dump(out);
	t0 = fake_now();
	fake_set_silent(true);
	sleep_ms(1000);
	t1 = fake_now();
	fake_set_silent(false);
	sleep_ms(500);
	writer_stop();
	b = dump(out);
	longest = longest_write(0, UINT64_MAX);
	expect(longest <= 110000, "a write took %" PRIu64 " us", longest);
	expect(longest >= 99000, "the longest write took %" PRIu64 " us, the bound was never reached", longest);
	expect(b.stalls > a.stalls, "no stall counted");
	expect(b.dropped > a.dropped, "no frame dropped");
	expect(b.written == atomic_load(&w.handed),
	       "written %" PRIu64 " of %" PRIu64 " handed, dropped frames not counted", b.written,
	       (uint64_t)atomic_load(&w.handed));
	n = writes_between(t0 - 200000, t0);
	want = 200000 / period_usec(256);
	expect(n <= want + 10 && n + 10 >= want, "%u writes in %u periods before the silence", n, want);
	n = writes_between(t1 + 50000, t1 + 450000);
	want = 400000 / period_usec(256);
	expect(n <= want + 10 && n + 10 >= want, "%u writes in %u periods after the silence", n, want);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();

	begin("no stall before the started callback");
	fake_set_silent(true);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(400);
	writer_stop();
	b = dump(out);
	expect(b.stalls == 0, "%u stalls before the stream started", b.stalls);
	expect(b.dropped > 0, "nothing dropped while the server never started");
	expect(b.written == atomic_load(&w.handed), "written %" PRIu64 " of %" PRIu64 " handed", b.written,
	       (uint64_t)atomic_load(&w.handed));
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_start_delay(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct stats a, b;
	int ret;

	begin("a sink start 50 ms after uncork");
	fake_set_start_delay(50000);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(300);
	a = dump(out);
	writer_hold();
	out->common.standby(&out->common);
	writer_release();
	sleep_ms(300);
	writer_stop();
	b = dump(out);
	expect(b.stalls == 0, "%u stalls", b.stalls);
	expect(b.dropped == a.dropped, "dropped %" PRIu64 " frames after the standby", b.dropped - a.dropped);
	expect(longest_write(0, UINT64_MAX) < 100000, "a write reached the bound");
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_position(void)
{
	static const unsigned int sinks[] = { 10, 40, 2 };
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct reader r;
	struct stats st, sb;
	struct timespec ts;
	uint64_t frames = 0;
	uint32_t render = 0;
	unsigned int samples;
	int64_t error;
	int ret;

	begin("position across standby, underflow, drop and a sink move");
	dev = dev_open();
	out = out_open(dev, &ret);
	expect(out->get_render_position(out, &render) < 0, "render position before the first write");
	writer_start(out, 256);
	memset(&r, 0, sizeof(r));
	r.out = out;
	r.w = &w;
	atomic_store(&r.run, true);
	pthread_create(&r.thread, NULL, reader_main, &r);
	for (unsigned int i = 0; i < sizeof(sinks) / sizeof(sinks[0]); i++) {
		fake_set_sink_latency(sinks[i] * 1000);
		sleep_ms(60);
		error = position_error(out, 140, &samples);
		expect(samples >= 50 && llabs(error) <= 512,
		       "the position is %" PRId64 " frames off what the sink played at %u ms, %u samples", error,
		       sinks[i], samples);
	}
	writer_hold();
	sleep_ms(40);
	writer_release();
	sleep_ms(200);
	writer_hold();
	out->common.standby(&out->common);
	sb = dump(out);
	writer_release();
	sleep_ms(200);
	fake_set_silent(true);
	sleep_ms(300);
	fake_set_silent(false);
	sleep_ms(200);
	atomic_store(&r.run, false);
	pthread_join(r.thread, NULL);
	writer_stop();
	st = dump(out);
	expect(r.reads > 1000, "%u position reads", r.reads);
	expect(r.decreases == 0, "the position went back %u times", r.decreases);
	expect(r.ahead == 0, "the position passed the written count %u times", r.ahead);
	expect(r.backwards == 0, "the timestamp went back %u times", r.backwards);
	expect(st.underflows >= 1, "no underflow counted");
	expect(st.dropped > 0, "no drop counted");
	expect(st.presented <= st.written, "presented %" PRIu64 " above written %" PRIu64, st.presented, st.written);
	expect(sb.presented == sb.written, "presented %" PRIu64 " of %" PRIu64 " written at standby", sb.presented,
	       sb.written);
	expect(!out->get_render_position(out, &render) && !out->get_presentation_position(out, &frames, &ts) &&
	       frames - render == sb.written,
	       "render position %u is not counted from the standby exit at %" PRIu64 ", presented %" PRIu64, render,
	       sb.written, frames);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_fill(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	unsigned int readings = 0, over = 0;
	int64_t most = -1;
	uint64_t t0;
	int ret;

	begin("the fill within tlength and a period with timing updates 1 s apart");
	fake_set_timing_interval(1000000);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	t0 = fake_now();
	while (fake_now() - t0 < 2500000) {
		struct stats st = dump(out);

		if (st.fill >= 0)
			readings++;
		if (st.fill > 4 * 256 * FRAME)
			over++;
		if (st.fill > most)
			most = st.fill;
		sleep_ms(10);
	}
	writer_stop();
	expect(readings > 0, "no fill reading");
	expect(over == 0, "%u dumps above %u bytes, the most %" PRId64, over, 4 * 256 * FRAME, most);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_server_down(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	uint64_t t0, t1, first, shortest, bound;
	unsigned int c0, c1, mark, lines, n, most;
	int ret;

	begin("the server down 5 s");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(300);
	c0 = fake_connects();
	mark = fake_log_mark();
	t0 = fake_now();
	fake_set_up(false);
	sleep_ms(5000);
	t1 = fake_now();
	c1 = fake_connects();
	fake_mark_write();
	fake_set_up(true);
	sleep_ms(500);
	writer_stop();
	lines = fake_log_since(mark);
	expect(c1 - c0 <= 51, "%u connect attempts", c1 - c0);
	expect(c1 - c0 >= 40, "only %u connect attempts", c1 - c0);
	shortest = shortest_write(t0 + 200000, t1);
	expect(shortest >= period_usec(256) * 9 / 10, "a write returned after %" PRIu64 " us while the server was down",
	       shortest);
	n = writes_between(t0 + 200000, t1);
	most = (t1 - t0 - 200000) / period_usec(256) + 2;
	expect(n <= most, "%u writes while the server was down, at most %u", n, most);
	expect(lines <= 3, "%u log lines", lines);
	expect(fake_log_count("reconnecting") == 1, "%u failure lines", fake_log_count("reconnecting"));
	first = fake_first_write();
	bound = 150000;
	expect(first && first - t1 <= bound, "audio back %" PRIu64 " us after the server, bound %" PRIu64,
	       first ? first - t1 : 0, bound);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_blocked_read(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	uint64_t longest = 0, t0;
	int ret;

	begin("position read during a blocked write");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(100);
	fake_set_silent(true);
	t0 = fake_now();
	sleep_ms(30);
	while (fake_now() - t0 < 150000) {
		struct timespec ts;
		uint64_t frames, t0, t1;
		uint32_t render;

		t0 = fake_now();
		out->get_presentation_position(out, &frames, &ts);
		out->get_render_position(out, &render);
		out->get_latency(out);
		out->common.get_buffer_size(&out->common);
		t1 = fake_now();
		if (t1 - t0 > longest)
			longest = t1 - t0;
		usleep(200);
	}
	fake_set_silent(false);
	writer_stop();
	expect(longest <= 5000, "a position read took %" PRIu64 " us", longest);
	expect(longest_write(0, UINT64_MAX) >= 99000, "the writer never blocked to the bound");
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_capture_start(void)
{
	static const struct {
		const char *name;
		uint64_t open_delay;
		uint64_t least;
	} cases[] = {
		{ "an input start with pulse down", 0, 1900000 },
		{ "an input start with a slow pulse", 500000, 500000 },
	};
	struct audio_config config = {
		.sample_rate = 16000,
		.channel_mask = AUDIO_CHANNEL_IN_STEREO,
		.format = AUDIO_FORMAT_PCM_32_BIT,
	};
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct capture c;
	pthread_t thread;
	struct stats a, b;
	uint64_t longest;
	int ret;

	for (unsigned int i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		begin(cases[i].name);
		fake_set_pcm_open_delay(cases[i].open_delay);
		dev = dev_open();
		out = out_open(dev, &ret);
		memset(&c, 0, sizeof(c));
		ret = dev->open_input_stream(dev, 0, AUDIO_DEVICE_IN_BUILTIN_MIC, &config, &c.in, AUDIO_INPUT_FLAG_NONE, "",
					     AUDIO_SOURCE_MIC);
		expect(!ret && c.in, "open_input_stream: %d", ret);
		writer_start(out, 256);
		sleep_ms(100);
		a = dump(out);
		if (c.in) {
			pthread_create(&thread, NULL, capture_main, &c);
			pthread_join(thread, NULL);
		}
		b = dump(out);
		writer_stop();
		longest = longest_write(0, UINT64_MAX);
		expect(c.end - c.begin >= cases[i].least, "the input start held the device %" PRIu64 " us, under %" PRIu64,
		       c.end - c.begin, cases[i].least);
		expect(longest <= 110000, "a write took %" PRIu64 " us during the input start", longest);
		expect(b.dropped == a.dropped, "dropped %" PRIu64 " frames during the input start", b.dropped - a.dropped);
		if (c.in)
			dev->close_input_stream(dev, c.in);
		dev->close_output_stream(dev, out);
		dev->common.close(&dev->common);
		end();
	}
}

static void case_stream_failed(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct stats a, b;
	unsigned int c0;
	int ret;

	begin("a stream failing while the context stays up");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(200);
	a = dump(out);
	c0 = fake_connects();
	fake_fail_stream();
	sleep_ms(300);
	writer_stop();
	b = dump(out);
	expect(fake_log_count("reopening") == 1, "%u stream failure lines", fake_log_count("reopening"));
	expect(fake_log_count("open again") == 1, "%u stream back lines", fake_log_count("open again"));
	expect(fake_connects() == c0, "%u context connects for a stream failure", fake_connects() - c0);
	expect(fake_streams() == 1, "%u streams, the failed one not released", fake_streams());
	expect(b.dropped - a.dropped <= 256, "dropped %" PRIu64 " frames across the reopen", b.dropped - a.dropped);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_start_line(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct start st;
	bool ok;
	int ret;

	begin("one start line per open and reopen");
	fake_set_connect_delay(20000);
	fake_set_stream_delay(30000);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(200);
	expect(fake_log_count(START_LINE) == 1, "%u start lines after the open", fake_log_count(START_LINE));
	ok = start_line(0, &st);
	expect(ok && !st.up && st.connect >= 20000 && st.connect < 60000 && st.create >= 30000 && st.create < 70000 &&
	       st.wait >= st.create && st.wait < 100000 && !st.dropped,
	       "open: up %d connect %" PRIu64 " create %" PRIu64 " wait %" PRIu64 " dropped %" PRIu64, st.up,
	       st.connect, st.create, st.wait, st.dropped);
	writer_hold();
	out->common.standby(&out->common);
	writer_release();
	sleep_ms(100);
	expect(fake_log_count(START_LINE) == 1, "%u start lines after a standby", fake_log_count(START_LINE));
	fake_fail_stream();
	sleep_ms(200);
	expect(fake_log_count(START_LINE) == 2, "%u start lines after a stream failure", fake_log_count(START_LINE));
	ok = start_line(1, &st);
	expect(ok && st.up && st.create >= 30000 && st.create < 70000 && st.wait >= st.create && st.wait < 100000 &&
	       !st.dropped,
	       "stream reopen: up %d create %" PRIu64 " wait %" PRIu64 " dropped %" PRIu64, st.up, st.create, st.wait,
	       st.dropped);
	fake_set_up(false);
	sleep_ms(300);
	fake_set_up(true);
	sleep_ms(300);
	expect(fake_log_count(START_LINE) == 3, "%u start lines after the server came back",
	       fake_log_count(START_LINE));
	ok = start_line(2, &st);
	expect(ok && !st.up && st.connect >= 20000 && st.connect < 60000 && st.create >= 30000 && st.create < 70000 &&
	       st.dropped == 256,
	       "server back: up %d connect %" PRIu64 " create %" PRIu64 " dropped %" PRIu64, st.up, st.connect,
	       st.create, st.dropped);
	writer_hold();
	dev->close_output_stream(dev, out);
	out = out_open(dev, &ret);
	expect(!ret && out, "second open_output_stream: %d", ret);
	atomic_store(&w.out, out);
	writer_release();
	sleep_ms(200);
	writer_stop();
	expect(fake_log_count(START_LINE) == 4, "%u start lines after a second open", fake_log_count(START_LINE));
	ok = start_line(3, &st);
	expect(ok && st.up && st.create >= 30000 && st.create < 70000 && st.wait >= st.create && st.wait < 100000 &&
	       !st.dropped,
	       "second open: up %d create %" PRIu64 " wait %" PRIu64 " dropped %" PRIu64, st.up, st.create, st.wait,
	       st.dropped);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();

	begin("a start line naming a first write past the bound");
	fake_set_stream_delay(150000);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(300);
	writer_stop();
	expect(fake_log_count(START_LINE) == 1, "%u start lines", fake_log_count(START_LINE));
	ok = start_line(0, &st);
	expect(ok && !st.up && st.create >= 150000 && st.create < 200000 && st.wait >= 99000 && st.wait <= 110000 &&
	       st.dropped == 256,
	       "up %d create %" PRIu64 " wait %" PRIu64 " dropped %" PRIu64, st.up, st.create, st.wait, st.dropped);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();

	begin("a stream failing before it came up keeps the first write");
	fake_set_stream_delay(150000);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(120);
	fake_set_up(false);
	sleep_ms(5);
	fake_set_up(true);
	sleep_ms(400);
	writer_stop();
	expect(fake_log_count(START_LINE) == 1, "%u start lines", fake_log_count(START_LINE));
	ok = start_line(0, &st);
	expect(ok && !st.up && st.wait >= 99000 && st.wait <= 110000 && st.dropped == 256,
	       "up %d wait %" PRIu64 " dropped %" PRIu64, st.up, st.wait, st.dropped);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_period_switch(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out, *next;
	struct stats a, b;
	struct start st;
	char value[64] = "";
	unsigned int c0;
	int ret;

	begin("a second output at another period while the first plays");
	fake_set_connect_delay(20000);
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(200);
	a = dump(out);
	c0 = fake_connects();
	fake_set_prop(PERIOD_PROP, "128");
	next = out_open(dev, &ret);
	expect(!ret && next, "second open_output_stream: %d", ret);
	sleep_ms(300);
	writer_stop();
	b = dump(out);
	expect(fake_connects() - c0 == 1, "%u context connects for the period switch", fake_connects() - c0);
	expect(fake_client_prop("pulse.min.req", value, sizeof(value)) && !strcmp(value, "128/48000"),
	       "pulse.min.req %s after the switch", value);
	expect(!fake_log_count("reopening") && !fake_log_count("reconnecting"), "the period switch logged a failure");
	expect(fake_streams() == 1, "%u streams, the first output's old stream not released", fake_streams());
	expect(b.dropped - a.dropped <= 256, "dropped %" PRIu64 " frames across the switch", b.dropped - a.dropped);
	expect(fake_log_count(START_LINE) == 2, "%u start lines across the switch", fake_log_count(START_LINE));
	expect(start_line(1, &st) && !st.up, "the first output's reopen read the context as up");
	if (next)
		dev->close_output_stream(dev, next);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

static void case_close_creating(void)
{
	static int16_t buf[256 * 2];
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	struct stats st;
	uint64_t t0, t1;
	int ret;

	begin("an output closed while its stream is created");
	fake_set_stream_delay(300000);
	dev = dev_open();
	out = out_open(dev, &ret);
	t0 = fake_now();
	out->write(out, buf, sizeof(buf));
	t1 = fake_now();
	st = dump(out);
	expect(t1 - t0 >= 99000 && t1 - t0 <= 110000, "the write took %" PRIu64 " us, not the bound", t1 - t0);
	expect(st.dropped == 256, "dropped %" PRIu64 " of the 256 frames written before the stream came up", st.dropped);
	dev->close_output_stream(dev, out);
	expect(fake_streams() == 1, "%u streams after the close, not the one being created", fake_streams());
	sleep_ms(300);
	expect(fake_streams() == 0, "%u streams after the orphan came up", fake_streams());
	dev->common.close(&dev->common);
	end();

	begin("the device closed while an orphan stream is created");
	fake_set_stream_delay(300000);
	dev = dev_open();
	out = out_open(dev, &ret);
	out->write(out, buf, sizeof(buf));
	dev->close_output_stream(dev, out);
	expect(fake_streams() == 1, "%u streams after the close, not the one being created", fake_streams());
	dev->common.close(&dev->common);
	end();
}

static void case_device_close(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	int ret;

	begin("the device closed with an output playing");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(100);
	writer_stop();
	expect(fake_streams() == 1, "%u streams before the device close", fake_streams());
	dev->common.close(&dev->common);
	end();
}

static void case_sched(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out, *next;
	struct fake_sched calls[64];
	unsigned int n, loop = 0, writer = 0, other = 0, wrong = 0;
	pid_t loop_tid;
	int ret;

	begin("the policy call once per thread");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(100);
	writer_hold();
	out->common.standby(&out->common);
	writer_release();
	sleep_ms(100);
	fake_set_up(false);
	sleep_ms(300);
	fake_set_up(true);
	sleep_ms(300);
	writer_hold();
	dev->close_output_stream(dev, out);
	next = out_open(dev, &ret);
	expect(!ret && next, "second open_output_stream: %d", ret);
	atomic_store(&w.out, next);
	writer_release();
	sleep_ms(100);
	writer_stop();
	loop_tid = fake_loop_tid();
	n = fake_sched_calls(calls, 64);
	for (unsigned int i = 0; i < n; i++) {
		if (calls[i].tid == loop_tid)
			loop++;
		else if (calls[i].tid == w.tid)
			writer++;
		else
			other++;
		if (calls[i].policy != (SCHED_FIFO | SCHED_RESET_ON_FORK) || calls[i].priority != 3)
			wrong++;
	}
	expect(loop == 1, "%u calls on the loop thread", loop);
	expect(writer == 2, "%u calls on the writer for two streams", writer);
	expect(other == 0, "%u calls on other threads", other);
	expect(wrong == 0, "%u calls not FIFO with RESET_ON_FORK at 3", wrong);
	dev->close_output_stream(dev, next);
	dev->common.close(&dev->common);
	end();
}

static void case_debug(void)
{
	audio_hw_device_t *dev;
	struct audio_stream_out *out;
	unsigned int quiet, mark, lines;
	int ret;

	begin("the per second line only with the debug prop");
	dev = dev_open();
	out = out_open(dev, &ret);
	writer_start(out, 256);
	sleep_ms(2500);
	quiet = fake_log_count(" underflows=");
	fake_set_prop(DEBUG_PROP, "1");
	mark = fake_log_count(" underflows=");
	sleep_ms(2500);
	lines = fake_log_count(" underflows=") - mark;
	writer_stop();
	expect(quiet == 0, "%u lines without the debug prop", quiet);
	expect(lines >= 2 && lines <= 3, "%u lines in 2.5 s with the debug prop", lines);
	dev->close_output_stream(dev, out);
	dev->common.close(&dev->common);
	end();
}

int main(void)
{
	alarm(180);
	setvbuf(stdout, NULL, _IOLBF, 0);
	case_attrs();
	case_period();
	case_late_request();
	case_silent();
	case_start_delay();
	case_position();
	case_fill();
	case_server_down();
	case_blocked_read();
	case_capture_start();
	case_stream_failed();
	case_start_line();
	case_period_switch();
	case_close_creating();
	case_device_close();
	case_sched();
	case_debug();
	if (failures)
		printf("audiotest: %d failures\n", failures);
	else
		printf("audiotest: every case passes\n");
	return failures != 0;
}
