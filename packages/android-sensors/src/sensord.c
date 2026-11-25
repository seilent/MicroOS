#include <errno.h>
#include <gbinder.h>
#include <glib-unix.h>
#include <gutil_log.h>
#include <linux/qrtr.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "ssc.h"

#define ME "waydroid-sensord"
#define DEVICE "/dev/hwbinder"
#define IFACE "android.hardware.sensors@1.0::ISensors"
#define INSTANCE "default"
#define VENDOR "MicroOS"
#define GRAVITY 9.80665f

enum {
	GET_SENSORS_LIST = GBINDER_FIRST_CALL_TRANSACTION,
	SET_OPERATION_MODE,
	ACTIVATE,
	POLL,
	BATCH,
	FLUSH,
	INJECT_SENSOR_DATA,
	REGISTER_DIRECT_CHANNEL,
	UNREGISTER_DIRECT_CHANNEL,
	CONFIG_DIRECT_REPORT,
};
enum { RESULT_OK = 0, RESULT_BAD_VALUE = -22, RESULT_INVALID_OPERATION = -38 };
enum { MODE_NORMAL = 0 };
enum { TYPE_META_DATA = 0, TYPE_ACCELEROMETER = 1, TYPE_LIGHT = 5 };
enum { FLAG_ON_CHANGE = 2 };
enum { META_FLUSH_COMPLETE = 1 };
enum { ACCEL, LIGHT, SENSORS };
enum { QUEUE = 512, POLL_MAX = 128, BUFFER = 65536 };
enum { ACCEL_MIN_DELAY_US = 10000, ACCEL_MAX_DELAY_US = 1000000 };
enum { AID_SYSTEM = 1000 };

struct sensor_info {
	gint32 handle;
	GBinderHidlString name;
	GBinderHidlString vendor;
	gint32 version;
	gint32 type;
	GBinderHidlString type_name;
	float max_range;
	float resolution;
	float power;
	gint32 min_delay;
	guint32 fifo_reserved;
	guint32 fifo_max;
	GBinderHidlString permission;
	gint32 max_delay;
	guint32 flags;
};

G_STATIC_ASSERT(sizeof(struct sensor_info) == 112);
G_STATIC_ASSERT(offsetof(struct sensor_info, name) == 8);
G_STATIC_ASSERT(offsetof(struct sensor_info, vendor) == 24);
G_STATIC_ASSERT(offsetof(struct sensor_info, type_name) == 48);
G_STATIC_ASSERT(offsetof(struct sensor_info, permission) == 88);
G_STATIC_ASSERT(offsetof(struct sensor_info, flags) == 108);

struct event {
	gint64 timestamp;
	gint32 handle;
	gint32 type;
	union {
		struct {
			float x;
			float y;
			float z;
			gint8 status;
		} vec3;
		float scalar;
		struct {
			guint32 what;
		} meta;
		guint64 align;
		guint8 data[64];
	} u;
};

G_STATIC_ASSERT(sizeof(struct event) == 80);
G_STATIC_ASSERT(offsetof(struct event, u) == 16);

struct stream {
	int fd;
	guint32 node;
	gboolean served;
	guint32 server_node;
	guint32 server_port;
	gboolean found;
	struct ssc_suid suid;
	guint16 txn;
	gboolean enabled;
	float rate;
};

struct sensor {
	const char *name;
	const char *type_name;
	const char *ssc;
	gint32 type;
	float max_range;
	float resolution;
	float power;
	gint32 min_delay;
	gint32 max_delay;
	guint32 flags;
	gboolean on;
	gint64 period;
	gint64 stamp;
	gboolean fresh;
	float last;
	struct stream stream;
};

struct report {
	struct sensor *sensor;
	struct ssc_suid suid;
};

static struct sensor sensors[SENSORS] = {
	[ACCEL] = {
		.name = "Accelerometer",
		.type_name = "android.sensor.accelerometer",
		.ssc = "accel",
		.type = TYPE_ACCELEROMETER,
		.max_range = 156.9064f,
		.resolution = 0.0047884f,
		.power = 0.24f,
		.min_delay = ACCEL_MIN_DELAY_US,
		.max_delay = ACCEL_MAX_DELAY_US,
		.period = 200000000,
	},
	[LIGHT] = {
		.name = "Ambient light",
		.type_name = "android.sensor.light",
		.ssc = "ambient_light",
		.type = TYPE_LIGHT,
		.max_range = 4096.0f,
		.resolution = 0.54f,
		.power = 0.09f,
		.flags = FLAG_ON_CHANGE,
	},
};

static const float turns[4][2] = { { 0, GRAVITY }, { GRAVITY, 0 }, { 0, -GRAVITY }, { -GRAVITY, 0 } };

static GMainLoop *loop;
static GBinderLocalObject *service;
static const char *device = DEVICE;
static gboolean registered;
static uid_t refused = (uid_t)-1;
static int code;
static struct event queue[QUEUE];
static guint head;
static guint queued;
static gboolean full;
static GBinderRemoteRequest *waiting;
static gint32 waiting_max;
static int turn = -1;
static guint ticker;

static void say(const char *format, ...) G_GNUC_PRINTF(1, 2);

static void say(const char *format, ...)
{
	va_list args;
	va_start(args, format);
	fputs(ME ": ", stderr);
	vfprintf(stderr, format, args);
	fputc('\n', stderr);
	va_end(args);
}

static gint64 now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_BOOTTIME, &ts);
	return (gint64)ts.tv_sec * G_GINT64_CONSTANT(1000000000) + ts.tv_nsec;
}

static gint32 handle_of(const struct sensor *sensor)
{
	return sensor - sensors + 1;
}

static struct sensor *find(gint32 handle)
{
	return handle >= 1 && handle <= SENSORS ? &sensors[handle - 1] : NULL;
}

static float sensor_rate(const struct sensor *sensor)
{
	gint64 period;

	if (sensor->flags & FLAG_ON_CHANGE)
		return 0;
	period = CLAMP(sensor->period, (gint64)sensor->min_delay * 1000, (gint64)sensor->max_delay * 1000);
	return 1e9f / period;
}

static void enqueue(const struct event *event)
{
	if (queued == QUEUE) {
		if (!full)
			say("event queue full, dropping the oldest events");
		full = TRUE;
		head = (head + 1) % QUEUE;
		queued--;
	}
	queue[(head + queued) % QUEUE] = *event;
	queued++;
}

static void push(struct sensor *sensor, struct event *event)
{
	gint64 t = now();

	if (t <= sensor->stamp)
		t = sensor->stamp + 1;
	sensor->stamp = t;
	event->timestamp = t;
	event->handle = handle_of(sensor);
	event->type = sensor->type;
	enqueue(event);
}

static GBinderLocalReply *result_reply(gint32 result)
{
	GBinderLocalReply *reply = gbinder_local_object_new_reply(service);
	gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
	gbinder_local_reply_append_int32(reply, result);
	return reply;
}

static GBinderLocalReply *poll_reply(gint32 result, guint max)
{
	struct event out[POLL_MAX];
	guint n = MIN(MIN(max, POLL_MAX), queued);
	GBinderLocalReply *reply;
	GBinderWriter writer;

	for (guint i = 0; i < n; i++) {
		out[i] = queue[head];
		head = (head + 1) % QUEUE;
	}
	queued -= n;
	if (!queued)
		full = FALSE;
	reply = gbinder_local_object_new_reply(service);
	gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
	gbinder_local_reply_init_writer(reply, &writer);
	gbinder_writer_append_int32(&writer, result);
	gbinder_writer_append_hidl_vec(&writer, n ? out : NULL, n, sizeof(struct event));
	gbinder_writer_append_hidl_vec(&writer, NULL, 0, sizeof(struct sensor_info));
	return reply;
}

static void poll_finish(guint max)
{
	GBinderLocalReply *reply = poll_reply(RESULT_OK, max);
	gbinder_remote_request_complete(waiting, reply, GBINDER_STATUS_OK);
	gbinder_local_reply_unref(reply);
	gbinder_remote_request_unref(waiting);
	waiting = NULL;
}

static void poll_wake(void)
{
	if (waiting && queued)
		poll_finish(waiting_max);
}

static GBinderLocalReply *poll_call(GBinderRemoteRequest *req, gint32 max)
{
	if (max <= 0)
		return poll_reply(RESULT_BAD_VALUE, 0);
	if (waiting)
		poll_finish(0);
	if (queued)
		return poll_reply(RESULT_OK, max);
	waiting = gbinder_remote_request_ref(req);
	waiting_max = max;
	gbinder_remote_request_block(req);
	return NULL;
}

static void put_string(GBinderHidlString *field, const char *value)
{
	field->data.str = value;
	field->len = strlen(value);
	field->owns_buffer = TRUE;
}

static void put_child(GBinderWriter *writer, guint parent, gsize offset, const GBinderHidlString *field)
{
	GBinderParent link = { parent, offset };
	gbinder_writer_append_buffer_object_with_parent(writer, field->data.str, field->len + 1, &link);
}

static GBinderLocalReply *sensor_list(void)
{
	GBinderLocalReply *reply = gbinder_local_object_new_reply(service);
	GBinderWriter writer;
	GBinderHidlVec *vec;
	struct sensor_info *info;
	GBinderParent parent;
	guint index;

	gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
	gbinder_local_reply_init_writer(reply, &writer);
	vec = gbinder_writer_new0(&writer, GBinderHidlVec);
	info = gbinder_writer_malloc0(&writer, sizeof(*info) * SENSORS);
	for (int i = 0; i < SENSORS; i++) {
		const struct sensor *sensor = &sensors[i];
		info[i].handle = handle_of(sensor);
		put_string(&info[i].name, sensor->name);
		put_string(&info[i].vendor, VENDOR);
		info[i].version = 1;
		info[i].type = sensor->type;
		put_string(&info[i].type_name, sensor->type_name);
		info[i].max_range = sensor->max_range;
		info[i].resolution = sensor->resolution;
		info[i].power = sensor->power;
		info[i].min_delay = sensor->min_delay;
		put_string(&info[i].permission, "");
		info[i].max_delay = sensor->max_delay;
		info[i].flags = sensor->flags;
	}
	vec->data.ptr = info;
	vec->count = SENSORS;
	vec->owns_buffer = TRUE;
	parent.index = gbinder_writer_append_buffer_object(&writer, vec, sizeof(*vec));
	parent.offset = GBINDER_HIDL_VEC_BUFFER_OFFSET;
	index = gbinder_writer_append_buffer_object_with_parent(&writer, info, sizeof(*info) * SENSORS, &parent);
	for (int i = 0; i < SENSORS; i++) {
		gsize base = sizeof(*info) * i;
		put_child(&writer, index, base + offsetof(struct sensor_info, name), &info[i].name);
		put_child(&writer, index, base + offsetof(struct sensor_info, vendor), &info[i].vendor);
		put_child(&writer, index, base + offsetof(struct sensor_info, type_name), &info[i].type_name);
		put_child(&writer, index, base + offsetof(struct sensor_info, permission), &info[i].permission);
	}
	return reply;
}

static gboolean stream_send(struct sensor *sensor, GByteArray *packet)
{
	struct stream *stream = &sensor->stream;
	struct sockaddr_qrtr to = {
		.sq_family = AF_QIPCRTR,
		.sq_node = stream->server_node,
		.sq_port = stream->server_port,
	};
	gboolean sent = sendto(stream->fd, packet->data, packet->len, 0, (struct sockaddr *)&to, sizeof(to)) >= 0;

	if (!sent)
		say("%s: send to %u:%u: %s", sensor->ssc, to.sq_node, to.sq_port, strerror(errno));
	g_byte_array_unref(packet);
	return sent;
}

static guint16 next_txn(struct stream *stream)
{
	stream->txn = stream->txn == G_MAXUINT16 ? 1 : stream->txn + 1;
	return stream->txn;
}

static void stream_apply(struct sensor *sensor)
{
	struct stream *stream = &sensor->stream;
	float rate = sensor_rate(sensor);

	if (!stream->found)
		return;
	if (stream->enabled && (!sensor->on || rate != stream->rate)) {
		if (!stream_send(sensor, ssc_disable_request(next_txn(stream), &stream->suid)))
			return;
		stream->enabled = FALSE;
		if (!sensor->on)
			say("%s: off", sensor->ssc);
	}
	if (sensor->on && !stream->enabled) {
		if (!stream_send(sensor, ssc_enable_request(next_txn(stream), &stream->suid, rate)))
			return;
		stream->enabled = TRUE;
		stream->rate = rate;
		if (rate > 0)
			say("%s: on at %g Hz", sensor->ssc, rate);
		else
			say("%s: on, reports on change", sensor->ssc);
	}
}

static void sensor_sample(struct sensor *sensor, const guint8 *payload, gsize len)
{
	struct event event = { 0 };
	float values[3];
	gint status;
	guint n = ssc_floats(payload, len, values, G_N_ELEMENTS(values), &status);

	if (!sensor->on)
		return;
	if (sensor == &sensors[ACCEL]) {
		if (n < 3 || turn >= 0)
			return;
		event.u.vec3.x = values[1];
		event.u.vec3.y = -values[0];
		event.u.vec3.z = values[2];
		event.u.vec3.status = status >= 0 && status <= 3 ? status : 0;
	} else {
		if (n < 1 || (!sensor->fresh && values[0] == sensor->last))
			return;
		sensor->fresh = FALSE;
		sensor->last = values[0];
		event.u.scalar = values[0];
	}
	push(sensor, &event);
}

static void stream_event(guint32 id, const guint8 *payload, gsize len, void *data)
{
	struct report *report = data;
	struct sensor *sensor = report->sensor;
	struct stream *stream = &sensor->stream;
	guint64 error;
	gint count;

	if (ssc_suid_equal(&report->suid, &ssc_lookup)) {
		if (id != SSC_SUID_EVENT || stream->found)
			return;
		count = ssc_suid_event(payload, len, sensor->ssc, &stream->suid);
		if (count == 0)
			say("%s: the sensor hub lists none", sensor->ssc);
		if (count <= 0)
			return;
		stream->found = TRUE;
		say("%s: suid %016" G_GINT64_MODIFIER "x%016" G_GINT64_MODIFIER "x", sensor->ssc, stream->suid.high,
		    stream->suid.low);
		stream_apply(sensor);
		return;
	}
	if (!stream->found || !ssc_suid_equal(&report->suid, &stream->suid))
		return;
	if (id == SSC_SENSOR_EVENT)
		sensor_sample(sensor, payload, len);
	else if (id == SSC_ERROR_EVENT && ssc_error_code(payload, len, &error))
		say("%s: error event %" G_GUINT64_FORMAT, sensor->ssc, error);
}

static void stream_message(struct sensor *sensor, const guint8 *buf, gsize len)
{
	struct ssc_message message;
	struct report report = { .sensor = sensor };
	guint16 result, error;

	if (!ssc_message(buf, len, &message))
		return;
	if (message.type == SSC_RESPONSE && message.id == SSC_CONTROL) {
		if (ssc_result(&message, &result, &error) && (result || error))
			say("%s: request %u returned %u/%u", sensor->ssc, message.txn, result, error);
		return;
	}
	if (message.type == SSC_INDICATION && (message.id == SSC_REPORT_SMALL || message.id == SSC_REPORT_LARGE))
		ssc_report(&message, &report.suid, stream_event, &report);
}

static void stream_control(struct sensor *sensor, const guint8 *buf, gsize len)
{
	struct stream *stream = &sensor->stream;
	struct qrtr_ctrl_pkt packet;
	guint32 cmd, id, node, port;

	if (len < sizeof(packet))
		return;
	memcpy(&packet, buf, sizeof(packet));
	cmd = GUINT32_FROM_LE(packet.cmd);
	id = GUINT32_FROM_LE(packet.server.service);
	node = GUINT32_FROM_LE(packet.server.node);
	port = GUINT32_FROM_LE(packet.server.port);
	if (cmd == QRTR_TYPE_NEW_SERVER && id == SSC_SERVICE && !stream->served) {
		stream->served = TRUE;
		stream->server_node = node;
		stream->server_port = port;
		say("%s: sensor hub at %u:%u", sensor->ssc, node, port);
		stream_send(sensor, ssc_suid_request(next_txn(stream), sensor->ssc));
	} else if (cmd == QRTR_TYPE_DEL_SERVER && stream->served && node == stream->server_node &&
		   port == stream->server_port) {
		say("%s: sensor hub at %u:%u is gone", sensor->ssc, node, port);
		stream->served = FALSE;
		stream->found = FALSE;
		stream->enabled = FALSE;
	}
}

static gboolean stream_readable(gint fd, GIOCondition condition, gpointer data)
{
	static guint8 buf[BUFFER];
	struct sensor *sensor = data;
	struct stream *stream = &sensor->stream;
	struct sockaddr_qrtr from;
	socklen_t size;
	gssize len;

	(void)condition;
	for (;;) {
		size = sizeof(from);
		len = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &size);
		if (len < 0) {
			if (errno == EINTR)
				continue;
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				say("%s: receive: %s", sensor->ssc, strerror(errno));
			break;
		}
		if (from.sq_port == QRTR_PORT_CTRL)
			stream_control(sensor, buf, len);
		else if (stream->served && from.sq_node == stream->server_node && from.sq_port == stream->server_port)
			stream_message(sensor, buf, len);
	}
	poll_wake();
	return G_SOURCE_CONTINUE;
}

static void stream_open(struct sensor *sensor)
{
	struct stream *stream = &sensor->stream;
	struct sockaddr_qrtr self;
	socklen_t size = sizeof(self);
	struct qrtr_ctrl_pkt packet = { 0 };
	struct sockaddr_qrtr to = { .sq_family = AF_QIPCRTR, .sq_port = QRTR_PORT_CTRL };

	stream->fd = socket(AF_QIPCRTR, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (stream->fd < 0) {
		say("%s: no QRTR socket: %s", sensor->ssc, strerror(errno));
		return;
	}
	if (getsockname(stream->fd, (struct sockaddr *)&self, &size) < 0) {
		say("%s: QRTR socket name: %s", sensor->ssc, strerror(errno));
		close(stream->fd);
		stream->fd = -1;
		return;
	}
	stream->node = self.sq_node;
	g_unix_fd_add(stream->fd, G_IO_IN, stream_readable, sensor);
	packet.cmd = GUINT32_TO_LE(QRTR_TYPE_NEW_LOOKUP);
	packet.server.service = GUINT32_TO_LE(SSC_SERVICE);
	to.sq_node = stream->node;
	if (sendto(stream->fd, &packet, sizeof(packet), 0, (struct sockaddr *)&to, sizeof(to)) < 0)
		say("%s: lookup: %s", sensor->ssc, strerror(errno));
}

static gboolean test_tick(gpointer data)
{
	struct event event = { 0 };

	(void)data;
	event.u.vec3.x = turns[turn][0];
	event.u.vec3.y = turns[turn][1];
	event.u.vec3.status = 3;
	push(&sensors[ACCEL], &event);
	poll_wake();
	return G_SOURCE_CONTINUE;
}

static void test_apply(void)
{
	const struct sensor *accel = &sensors[ACCEL];

	if (ticker) {
		g_source_remove(ticker);
		ticker = 0;
	}
	if (turn >= 0 && accel->on)
		ticker = g_timeout_add(MAX(1, (guint)(1000 / sensor_rate(accel))), test_tick, NULL);
}

static gboolean test_turn(gpointer data)
{
	(void)data;
	turn = turn < 0 ? 1 : (turn + 1) % 4;
	say("test input: turn %d", turn);
	test_apply();
	return G_SOURCE_CONTINUE;
}

static gboolean test_off(gpointer data)
{
	(void)data;
	if (turn >= 0) {
		turn = -1;
		say("test input off");
		test_apply();
	}
	return G_SOURCE_CONTINUE;
}

static gint32 activate(gint32 handle, gboolean enabled)
{
	struct sensor *sensor = find(handle);

	if (!sensor)
		return RESULT_BAD_VALUE;
	enabled = enabled != FALSE;
	if (sensor->on != enabled) {
		sensor->on = enabled;
		sensor->fresh = TRUE;
		stream_apply(sensor);
		test_apply();
	}
	return RESULT_OK;
}

static gint32 batch(gint32 handle, gint64 period)
{
	struct sensor *sensor = find(handle);

	if (!sensor || period < 0)
		return RESULT_BAD_VALUE;
	sensor->period = period;
	stream_apply(sensor);
	test_apply();
	return RESULT_OK;
}

static gint32 flush(gint32 handle)
{
	struct sensor *sensor = find(handle);
	struct event event = { 0 };

	if (!sensor || !sensor->on)
		return RESULT_BAD_VALUE;
	event.timestamp = now();
	event.handle = handle;
	event.type = TYPE_META_DATA;
	event.u.meta.what = META_FLUSH_COMPLETE;
	enqueue(&event);
	poll_wake();
	return RESULT_OK;
}

static GBinderLocalReply *transact(GBinderLocalObject *obj, GBinderRemoteRequest *req, guint call, guint flags,
				   int *status, void *data)
{
	GBinderReader reader;
	GBinderLocalReply *reply;
	gint32 handle, value;
	gint64 period, latency;
	gboolean enabled;
	uid_t euid;

	(void)obj;
	(void)flags;
	(void)data;
	*status = GBINDER_STATUS_OK;
	if (g_strcmp0(gbinder_remote_request_interface(req), IFACE)) {
		*status = -EBADMSG;
		return NULL;
	}
	euid = gbinder_remote_request_sender_euid(req);
	if (euid != AID_SYSTEM) {
		if (euid != refused)
			say("refused call %u from uid %u", call, (unsigned)euid);
		refused = euid;
		*status = -EPERM;
		return NULL;
	}
	gbinder_remote_request_init_reader(req, &reader);
	switch (call) {
	case GET_SENSORS_LIST:
		return sensor_list();
	case SET_OPERATION_MODE:
		if (!gbinder_reader_read_int32(&reader, &value))
			break;
		return result_reply(value == MODE_NORMAL ? RESULT_OK : RESULT_INVALID_OPERATION);
	case ACTIVATE:
		if (!gbinder_reader_read_int32(&reader, &handle) || !gbinder_reader_read_bool(&reader, &enabled))
			break;
		return result_reply(activate(handle, enabled));
	case POLL:
		if (!gbinder_reader_read_int32(&reader, &value))
			break;
		return poll_call(req, value);
	case BATCH:
		if (!gbinder_reader_read_int32(&reader, &handle) || !gbinder_reader_read_int64(&reader, &period) ||
		    !gbinder_reader_read_int64(&reader, &latency))
			break;
		return result_reply(batch(handle, period));
	case FLUSH:
		if (!gbinder_reader_read_int32(&reader, &handle))
			break;
		return result_reply(flush(handle));
	case INJECT_SENSOR_DATA:
	case UNREGISTER_DIRECT_CHANNEL:
		return result_reply(RESULT_INVALID_OPERATION);
	case REGISTER_DIRECT_CHANNEL:
	case CONFIG_DIRECT_REPORT:
		reply = result_reply(RESULT_INVALID_OPERATION);
		gbinder_local_reply_append_int32(reply, -1);
		return reply;
	default:
		*status = -EBADMSG;
		return NULL;
	}
	*status = -EINVAL;
	return NULL;
}

static void added(GBinderServiceManager *manager, int status, void *data)
{
	char **names;
	gboolean listed = FALSE;

	(void)data;
	if (!gbinder_servicemanager_is_present(manager))
		return;
	if (!status) {
		names = gbinder_servicemanager_list_sync(manager);
		listed = names && g_strv_contains((const char *const *)names, IFACE "/" INSTANCE);
		g_strfreev(names);
	}
	if (listed) {
		say(IFACE "/" INSTANCE " added on %s", device);
		return;
	}
	say("adding " IFACE "/" INSTANCE " on %s returned %d%s", device, status, status ? "" : ", not listed");
	code = 1;
	g_main_loop_quit(loop);
}

static void lost(void)
{
	if (waiting)
		poll_finish(0);
	head = 0;
	queued = 0;
	full = FALSE;
	for (int i = 0; i < SENSORS; i++) {
		if (sensors[i].on) {
			sensors[i].on = FALSE;
			stream_apply(&sensors[i]);
		}
	}
	test_apply();
}

static void presence(GBinderServiceManager *manager, void *data)
{
	(void)data;
	if (gbinder_servicemanager_is_present(manager)) {
		if (!registered) {
			registered = TRUE;
			gbinder_servicemanager_add_service(manager, INSTANCE, service, added, NULL);
		}
	} else if (registered) {
		registered = FALSE;
		say("the service manager on %s is gone", device);
		lost();
	}
}

static gboolean quit(gpointer data)
{
	(void)data;
	g_main_loop_quit(loop);
	return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv)
{
	GBinderServiceManager *manager;
	gulong handler;

	if (argc > 1)
		device = argv[1];
	gutil_log_timestamp = FALSE;
	gutil_log_set_type(GLOG_TYPE_STDERR, ME);
	gutil_log_default.level = GLOG_LEVEL_WARN;
	loop = g_main_loop_new(NULL, FALSE);
	manager = gbinder_servicemanager_new2(device, "hidl", "hidl");
	if (!manager) {
		say("no service manager on %s", device);
		return 1;
	}
	service = gbinder_servicemanager_new_local_object(manager, IFACE, transact, NULL);
	for (int i = 0; i < SENSORS; i++)
		stream_open(&sensors[i]);
	g_unix_signal_add(SIGTERM, quit, NULL);
	g_unix_signal_add(SIGINT, quit, NULL);
	g_unix_signal_add(SIGUSR1, test_turn, NULL);
	g_unix_signal_add(SIGUSR2, test_off, NULL);
	handler = gbinder_servicemanager_add_presence_handler(manager, presence, NULL);
	presence(manager, NULL);
	g_main_loop_run(loop);
	gbinder_servicemanager_remove_handler(manager, handler);
	for (int i = 0; i < SENSORS; i++)
		if (sensors[i].stream.fd >= 0)
			close(sensors[i].stream.fd);
	gbinder_local_object_unref(service);
	gbinder_servicemanager_unref(manager);
	g_main_loop_unref(loop);
	return code;
}
