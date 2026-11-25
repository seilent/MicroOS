#include <dlfcn.h>
#include <errno.h>
#include <gbinder.h>
#include <glib-unix.h>
#include <linux/qrtr.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef RTLD_NEXT
#define RTLD_NEXT ((void *)-1l)
#endif

enum { SOCKETS = 8, ARGS = 8 };

struct gbinder_servicemanager {
	gboolean present;
	GBinderServiceManagerFunc func;
	void *data;
};

struct gbinder_local_object {
	GBinderLocalTransactFunc handler;
	void *data;
};

struct gbinder_local_reply {
	gint refs;
	GString *items;
	GPtrArray *blocks;
	guint objects;
};

struct arg {
	char type;
	gint64 value;
};

struct gbinder_remote_request {
	gint refs;
	guint id;
	uid_t euid;
	char *iface;
	struct arg args[ARGS];
	guint count;
	gboolean blocked;
};

static struct gbinder_servicemanager manager;
static struct gbinder_local_object object;
static int ctl = -1;
static GString *line;
static int peers[SOCKETS];
static int ends[SOCKETS];
static guint sockets;
static int add_status;
static gboolean unlisted;
static gboolean added_once;

static void emit(const char *format, ...) G_GNUC_PRINTF(1, 2);

static void emit(const char *format, ...)
{
	va_list args;
	char *text;

	va_start(args, format);
	text = g_strdup_vprintf(format, args);
	va_end(args);
	if (write(ctl, text, strlen(text)) < 0 || write(ctl, "\n", 1) < 0)
		abort();
	g_free(text);
}

static void hex(GString *out, const void *data, gsize len)
{
	const guint8 *p = data;
	if (!len)
		g_string_append_c(out, '-');
	for (gsize i = 0; i < len; i++)
		g_string_append_printf(out, "%02x", p[i]);
}

static guint8 *unhex(const char *text, gsize *len)
{
	gsize n = strlen(text) / 2;
	guint8 *out = g_malloc(n + 1);
	for (gsize i = 0; i < n; i++)
		sscanf(text + 2 * i, "%2hhx", &out[i]);
	*len = n;
	return out;
}

static int find_socket(int fd)
{
	for (guint i = 0; i < sockets; i++)
		if (ends[i] == fd)
			return i;
	return -1;
}

static void reply_item(GBinderLocalReply *reply, const char *format, ...) G_GNUC_PRINTF(2, 3);

static void reply_item(GBinderLocalReply *reply, const char *format, ...)
{
	va_list args;

	if (reply->items->len)
		g_string_append_c(reply->items, ';');
	va_start(args, format);
	g_string_append_vprintf(reply->items, format, args);
	va_end(args);
}

static guint reply_buffer(GBinderLocalReply *reply, const void *buf, gsize len, const GBinderParent *parent)
{
	guint index = reply->objects++;

	if (parent)
		reply_item(reply, "buf %u %u@%u %zu ", index, parent->index, parent->offset, len);
	else
		reply_item(reply, "buf %u none %zu ", index, len);
	hex(reply->items, buf, len);
	return index;
}

static void call(GStrv words)
{
	GBinderRemoteRequest *req = g_new0(GBinderRemoteRequest, 1);
	GBinderLocalReply *reply;
	int status = 1234;

	req->refs = 1;
	req->id = atoi(words[1]);
	req->euid = 1000;
	req->iface = g_strdup(words[3]);
	for (int i = 4; words[i] && req->count < ARGS; i++) {
		if (words[i][0] == 'u') {
			req->euid = strtoul(words[i] + 2, NULL, 10);
			continue;
		}
		req->args[req->count].type = words[i][0];
		req->args[req->count].value = g_ascii_strtoll(words[i] + 2, NULL, 10);
		req->count++;
	}
	reply = object.handler(&object, req, atoi(words[2]), 0, &status, object.data);
	if (reply) {
		emit("reply %u %d %s", req->id, status, reply->items->str);
		gbinder_local_reply_unref(reply);
	} else if (req->blocked) {
		emit("blocked %u %d", req->id, status);
	} else {
		emit("status %u %d", req->id, status);
	}
	gbinder_remote_request_unref(req);
}

static void inject(GStrv words)
{
	gsize len;
	guint8 *payload = unhex(words[4], &len);
	guint8 *buf = g_malloc(len + 8);
	guint32 node = strtoul(words[2], NULL, 10), port = strtoul(words[3], NULL, 10);
	int id = atoi(words[1]);

	memcpy(buf, &node, 4);
	memcpy(buf + 4, &port, 4);
	memcpy(buf + 8, payload, len);
	if (send(peers[id], buf, len + 8, 0) < 0)
		abort();
	g_free(buf);
	g_free(payload);
}

static gboolean pong(gpointer data)
{
	emit("pong %s", (char *)data);
	g_free(data);
	return G_SOURCE_REMOVE;
}

static void command(const char *text)
{
	GStrv words = g_strsplit(text, " ", -1);

	if (!g_strcmp0(words[0], "present")) {
		manager.present = atoi(words[1]);
		if (manager.func)
			manager.func(&manager, manager.data);
	} else if (!g_strcmp0(words[0], "addstatus")) {
		add_status = atoi(words[1]);
	} else if (!g_strcmp0(words[0], "call")) {
		call(words);
	} else if (!g_strcmp0(words[0], "ssc")) {
		inject(words);
	} else if (!g_strcmp0(words[0], "unlisted")) {
		unlisted = TRUE;
	} else if (!g_strcmp0(words[0], "ping")) {
		g_idle_add(pong, g_strdup(words[1]));
	}
	g_strfreev(words);
}

static gboolean readable(gint fd, GIOCondition condition, gpointer data)
{
	char buf[65536];
	gssize n = read(fd, buf, sizeof(buf));

	(void)condition;
	(void)data;
	if (n <= 0)
		exit(3);
	for (gssize i = 0; i < n; i++) {
		if (buf[i] != '\n') {
			g_string_append_c(line, buf[i]);
			continue;
		}
		command(line->str);
		g_string_truncate(line, 0);
	}
	return G_SOURCE_CONTINUE;
}

static void setup(void)
{
	if (ctl >= 0)
		return;
	ctl = atoi(getenv("FAKE_CTL"));
	line = g_string_new(NULL);
	g_unix_fd_add(ctl, G_IO_IN, readable, NULL);
}

GBinderServiceManager *gbinder_servicemanager_new2(const char *dev, const char *sm, const char *rpc)
{
	setup();
	emit("manager %s %s %s", dev, sm, rpc);
	return &manager;
}

GBinderLocalObject *gbinder_servicemanager_new_local_object(GBinderServiceManager *sm, const char *iface,
							    GBinderLocalTransactFunc handler, void *data)
{
	(void)sm;
	emit("object %s", iface);
	object.handler = handler;
	object.data = data;
	return &object;
}

gboolean gbinder_servicemanager_is_present(GBinderServiceManager *sm)
{
	return sm->present;
}

gulong gbinder_servicemanager_add_presence_handler(GBinderServiceManager *sm, GBinderServiceManagerFunc func,
						    void *data)
{
	sm->func = func;
	sm->data = data;
	return 1;
}

void gbinder_servicemanager_remove_handler(GBinderServiceManager *sm, gulong id)
{
	(void)id;
	sm->func = NULL;
}

struct added {
	GBinderServiceManagerAddServiceFunc func;
	void *data;
};

static gboolean add_done(gpointer data)
{
	struct added *added = data;
	added->func(&manager, add_status, added->data);
	g_free(added);
	return G_SOURCE_REMOVE;
}

gulong gbinder_servicemanager_add_service(GBinderServiceManager *sm, const char *name, GBinderLocalObject *obj,
					  GBinderServiceManagerAddServiceFunc func, void *data)
{
	struct added *added = g_new0(struct added, 1);

	(void)sm;
	emit("add %s %s", name, obj == &object ? "object" : "other");
	added_once = TRUE;
	added->func = func;
	added->data = data;
	g_idle_add(add_done, added);
	return 1;
}

char **gbinder_servicemanager_list_sync(GBinderServiceManager *sm)
{
	GStrvBuilder *names = g_strv_builder_new();
	char **out;

	(void)sm;
	g_strv_builder_add(names, "android.hidl.manager@1.0::IServiceManager/default");
	if (added_once && !unlisted)
		g_strv_builder_add(names, "android.hardware.sensors@1.0::ISensors/default");
	out = g_strv_builder_end(names);
	g_strv_builder_unref(names);
	return out;
}

void gbinder_servicemanager_unref(GBinderServiceManager *sm)
{
	(void)sm;
}

void gbinder_local_object_unref(GBinderLocalObject *obj)
{
	(void)obj;
}

GBinderLocalReply *gbinder_local_object_new_reply(GBinderLocalObject *obj)
{
	GBinderLocalReply *reply = g_new0(GBinderLocalReply, 1);

	(void)obj;
	reply->refs = 1;
	reply->items = g_string_new(NULL);
	reply->blocks = g_ptr_array_new_with_free_func(g_free);
	return reply;
}

void gbinder_local_reply_unref(GBinderLocalReply *reply)
{
	if (--reply->refs)
		return;
	g_string_free(reply->items, TRUE);
	g_ptr_array_free(reply->blocks, TRUE);
	g_free(reply);
}

GBinderLocalReply *gbinder_local_reply_append_int32(GBinderLocalReply *reply, guint32 value)
{
	reply_item(reply, "i32 %d", (gint32)value);
	return reply;
}

void gbinder_local_reply_init_writer(GBinderLocalReply *reply, GBinderWriter *writer)
{
	memset(writer, 0, sizeof(*writer));
	writer->d[0] = reply;
}

void gbinder_writer_append_int32(GBinderWriter *writer, guint32 value)
{
	gbinder_local_reply_append_int32((GBinderLocalReply *)writer->d[0], value);
}

void *gbinder_writer_malloc0(GBinderWriter *writer, gsize size)
{
	GBinderLocalReply *reply = (GBinderLocalReply *)writer->d[0];
	void *block = g_malloc0(size);
	g_ptr_array_add(reply->blocks, block);
	return block;
}

guint gbinder_writer_append_buffer_object(GBinderWriter *writer, const void *buf, gsize len)
{
	return reply_buffer((GBinderLocalReply *)writer->d[0], buf, len, NULL);
}

guint gbinder_writer_append_buffer_object_with_parent(GBinderWriter *writer, const void *buf, gsize len,
						      const GBinderParent *parent)
{
	return reply_buffer((GBinderLocalReply *)writer->d[0], buf, len, parent);
}

void gbinder_writer_append_hidl_vec(GBinderWriter *writer, const void *base, guint count, guint elemsize)
{
	GBinderLocalReply *reply = (GBinderLocalReply *)writer->d[0];
	GBinderHidlVec vec = { .count = base ? count : 0, .owns_buffer = TRUE };
	GBinderParent parent = { 0, GBINDER_HIDL_VEC_BUFFER_OFFSET };

	vec.data.ptr = base;
	parent.index = reply_buffer(reply, &vec, sizeof(vec), NULL);
	reply_buffer(reply, base, (gsize)vec.count * elemsize, &parent);
}

uid_t gbinder_remote_request_sender_euid(GBinderRemoteRequest *req)
{
	return req->euid;
}

const char *gbinder_remote_request_interface(GBinderRemoteRequest *req)
{
	return req->iface;
}

void gbinder_remote_request_init_reader(GBinderRemoteRequest *req, GBinderReader *reader)
{
	memset(reader, 0, sizeof(*reader));
	reader->d[0] = req;
}

static struct arg *next_arg(GBinderReader *reader, char type)
{
	GBinderRemoteRequest *req = (GBinderRemoteRequest *)reader->d[0];
	guint pos = GPOINTER_TO_UINT(reader->d[1]);

	if (pos >= req->count || req->args[pos].type != type)
		return NULL;
	reader->d[1] = GUINT_TO_POINTER(pos + 1);
	return &req->args[pos];
}

gboolean gbinder_reader_read_int32(GBinderReader *reader, gint32 *value)
{
	struct arg *arg = next_arg(reader, 'i');
	if (arg)
		*value = arg->value;
	return arg != NULL;
}

gboolean gbinder_reader_read_int64(GBinderReader *reader, gint64 *value)
{
	struct arg *arg = next_arg(reader, 'l');
	if (arg)
		*value = arg->value;
	return arg != NULL;
}

gboolean gbinder_reader_read_bool(GBinderReader *reader, gboolean *value)
{
	struct arg *arg = next_arg(reader, 'b');
	if (arg)
		*value = arg->value != 0;
	return arg != NULL;
}

GBinderRemoteRequest *gbinder_remote_request_ref(GBinderRemoteRequest *req)
{
	req->refs++;
	return req;
}

void gbinder_remote_request_unref(GBinderRemoteRequest *req)
{
	if (--req->refs)
		return;
	g_free(req->iface);
	g_free(req);
}

void gbinder_remote_request_block(GBinderRemoteRequest *req)
{
	req->blocked = TRUE;
}

void gbinder_remote_request_complete(GBinderRemoteRequest *req, GBinderLocalReply *reply, int status)
{
	emit("complete %u %d %s", req->id, status, reply->items->str);
}

int socket(int domain, int type, int protocol)
{
	static int (*real)(int, int, int);
	int pair[2];

	if (!real)
		real = dlsym(RTLD_NEXT, "socket");
	if (domain != AF_QIPCRTR)
		return real(domain, type, protocol);
	if (getenv("FAKE_NOQRTR")) {
		errno = EAFNOSUPPORT;
		return -1;
	}
	if (sockets == SOCKETS || socketpair(AF_UNIX, SOCK_DGRAM | (type & (SOCK_NONBLOCK | SOCK_CLOEXEC)), 0, pair))
		abort();
	ends[sockets] = pair[0];
	peers[sockets] = pair[1];
	emit("socket %u", sockets);
	sockets++;
	return pair[0];
}

int getsockname(int fd, struct sockaddr *addr, socklen_t *len)
{
	static int (*real)(int, struct sockaddr *, socklen_t *);
	struct sockaddr_qrtr self = { .sq_family = AF_QIPCRTR, .sq_node = 1, .sq_port = 0 };

	if (!real)
		real = dlsym(RTLD_NEXT, "getsockname");
	if (find_socket(fd) < 0)
		return real(fd, addr, len);
	memcpy(addr, &self, MIN(*len, sizeof(self)));
	*len = sizeof(self);
	return 0;
}

ssize_t sendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *addr, socklen_t addrlen)
{
	static ssize_t (*real)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
	const struct sockaddr_qrtr *to = (const struct sockaddr_qrtr *)addr;
	int id = find_socket(fd);
	GString *out;

	if (!real)
		real = dlsym(RTLD_NEXT, "sendto");
	if (id < 0)
		return real(fd, buf, len, flags, addr, addrlen);
	out = g_string_new(NULL);
	g_string_printf(out, "sent %d %u %u ", id, to->sq_node, to->sq_port);
	hex(out, buf, len);
	emit("%s", out->str);
	g_string_free(out, TRUE);
	return len;
}

ssize_t recvfrom(int fd, void *buf, size_t len, int flags, struct sockaddr *addr, socklen_t *addrlen)
{
	static ssize_t (*real)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
	struct sockaddr_qrtr from = { .sq_family = AF_QIPCRTR };
	guint8 packet[65536 + 8];
	ssize_t n;

	if (!real)
		real = dlsym(RTLD_NEXT, "recvfrom");
	if (find_socket(fd) < 0)
		return real(fd, buf, len, flags, addr, addrlen);
	n = recv(fd, packet, sizeof(packet), flags);
	if (n < 0)
		return n;
	if (n < 8)
		abort();
	memcpy(&from.sq_node, packet, 4);
	memcpy(&from.sq_port, packet + 4, 4);
	n = MIN((size_t)(n - 8), len);
	memcpy(buf, packet + 8, n);
	memcpy(addr, &from, MIN(*addrlen, sizeof(from)));
	*addrlen = sizeof(from);
	return n;
}
