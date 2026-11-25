#include "ssc.h"

#include <string.h>

enum { VARINT = 0, FIXED64 = 1, BYTES = 2, FIXED32 = 5 };
enum { HEADER = 7 };
enum { DISABLE = 10, SUID_REQUEST = 512, SET_RATE = 513, ON_CHANGE = 514 };
enum { PROCESSOR_APSS = 1, DELIVERY_NO_WAKEUP = 1 };
enum { TLV_REQUEST = 0x01, TLV_DATA = 0x02, TLV_JUMBO = 0x10 };

const struct ssc_suid ssc_lookup = { 0xababababababababULL, 0xababababababababULL };

struct field {
	guint32 id;
	guint wire;
	guint64 value;
	const guint8 *data;
	gsize len;
};

static void put_varint(GByteArray *buf, guint64 value)
{
	guint8 byte;
	while (value >= 0x80) {
		byte = (value & 0x7f) | 0x80;
		g_byte_array_append(buf, &byte, 1);
		value >>= 7;
	}
	byte = value;
	g_byte_array_append(buf, &byte, 1);
}

static void put_key(GByteArray *buf, guint32 id, guint wire)
{
	put_varint(buf, (guint64)id << 3 | wire);
}

static void put_uint(GByteArray *buf, guint32 id, guint64 value)
{
	put_key(buf, id, VARINT);
	put_varint(buf, value);
}

static void put_fixed32(GByteArray *buf, guint32 id, guint32 value)
{
	guint32 le = GUINT32_TO_LE(value);
	put_key(buf, id, FIXED32);
	g_byte_array_append(buf, (const guint8 *)&le, sizeof(le));
}

static void put_fixed64(GByteArray *buf, guint32 id, guint64 value)
{
	guint64 le = GUINT64_TO_LE(value);
	put_key(buf, id, FIXED64);
	g_byte_array_append(buf, (const guint8 *)&le, sizeof(le));
}

static void put_bytes(GByteArray *buf, guint32 id, const guint8 *data, gsize len)
{
	put_key(buf, id, BYTES);
	put_varint(buf, len);
	g_byte_array_append(buf, data, len);
}

static void put_message(GByteArray *buf, guint32 id, GByteArray *inner)
{
	put_bytes(buf, id, inner->data, inner->len);
	g_byte_array_unref(inner);
}

static void put_le16(GByteArray *buf, guint16 value)
{
	guint16 le = GUINT16_TO_LE(value);
	g_byte_array_append(buf, (const guint8 *)&le, sizeof(le));
}

static void put_tlv(GByteArray *buf, guint8 id, const guint8 *data, gsize len)
{
	g_byte_array_append(buf, &id, 1);
	put_le16(buf, len);
	g_byte_array_append(buf, data, len);
}

static GByteArray *suid_bytes(const struct ssc_suid *suid)
{
	GByteArray *buf = g_byte_array_new();
	put_fixed64(buf, 1, suid->low);
	put_fixed64(buf, 2, suid->high);
	return buf;
}

static GByteArray *control(guint16 txn, GByteArray *msg)
{
	static const guint8 jumbo = 1;
	GByteArray *payload = g_byte_array_new();
	GByteArray *tlvs = g_byte_array_new();
	GByteArray *buf = g_byte_array_new();
	guint8 type = SSC_REQUEST;

	put_le16(payload, msg->len);
	g_byte_array_append(payload, msg->data, msg->len);
	put_tlv(tlvs, TLV_REQUEST, payload->data, payload->len);
	put_tlv(tlvs, TLV_JUMBO, &jumbo, 1);
	g_byte_array_append(buf, &type, 1);
	put_le16(buf, txn);
	put_le16(buf, SSC_CONTROL);
	put_le16(buf, tlvs->len);
	g_byte_array_append(buf, tlvs->data, tlvs->len);
	g_byte_array_unref(msg);
	g_byte_array_unref(payload);
	g_byte_array_unref(tlvs);
	return buf;
}

static GByteArray *request(guint16 txn, const struct ssc_suid *suid, guint32 id, GByteArray *payload)
{
	GByteArray *config = g_byte_array_new();
	GByteArray *body = g_byte_array_new();
	GByteArray *msg = g_byte_array_new();

	put_uint(config, 1, PROCESSOR_APSS);
	put_uint(config, 2, DELIVERY_NO_WAKEUP);
	if (payload)
		put_message(body, 2, payload);
	put_message(msg, 1, suid_bytes(suid));
	put_fixed32(msg, 2, id);
	put_message(msg, 3, config);
	put_message(msg, 4, body);
	return control(txn, msg);
}

gboolean ssc_suid_equal(const struct ssc_suid *a, const struct ssc_suid *b)
{
	return a->low == b->low && a->high == b->high;
}

GByteArray *ssc_suid_request(guint16 txn, const char *type)
{
	GByteArray *payload = g_byte_array_new();
	put_bytes(payload, 1, (const guint8 *)type, strlen(type));
	put_uint(payload, 2, 0);
	put_uint(payload, 3, 1);
	return request(txn, &ssc_lookup, SUID_REQUEST, payload);
}

GByteArray *ssc_enable_request(guint16 txn, const struct ssc_suid *suid, float rate)
{
	GByteArray *payload = g_byte_array_new();
	guint32 bits;

	if (rate <= 0)
		return request(txn, suid, ON_CHANGE, payload);
	memcpy(&bits, &rate, sizeof(bits));
	put_fixed32(payload, 1, bits);
	return request(txn, suid, SET_RATE, payload);
}

GByteArray *ssc_disable_request(guint16 txn, const struct ssc_suid *suid)
{
	return request(txn, suid, DISABLE, NULL);
}

static gboolean read_varint(const guint8 **pos, const guint8 *end, guint64 *out)
{
	guint64 value = 0;
	for (guint shift = 0; shift < 64; shift += 7) {
		if (*pos >= end)
			return FALSE;
		guint8 byte = *(*pos)++;
		value |= (guint64)(byte & 0x7f) << shift;
		if (!(byte & 0x80)) {
			*out = value;
			return TRUE;
		}
	}
	return FALSE;
}

static gboolean next_field(const guint8 **pos, const guint8 *end, struct field *field)
{
	guint64 key, len;
	guint32 le32;
	guint64 le64;

	if (*pos >= end || !read_varint(pos, end, &key))
		return FALSE;
	field->id = key >> 3;
	field->wire = key & 7;
	field->value = 0;
	field->data = NULL;
	field->len = 0;
	switch (field->wire) {
	case VARINT:
		return read_varint(pos, end, &field->value);
	case FIXED64:
		if (end - *pos < 8)
			return FALSE;
		memcpy(&le64, *pos, 8);
		field->value = GUINT64_FROM_LE(le64);
		*pos += 8;
		return TRUE;
	case FIXED32:
		if (end - *pos < 4)
			return FALSE;
		memcpy(&le32, *pos, 4);
		field->value = GUINT32_FROM_LE(le32);
		*pos += 4;
		return TRUE;
	case BYTES:
		if (!read_varint(pos, end, &len) || len > (guint64)(end - *pos))
			return FALSE;
		field->data = *pos;
		field->len = len;
		*pos += len;
		return TRUE;
	}
	return FALSE;
}

static guint16 le16(const guint8 *p)
{
	return p[0] | p[1] << 8;
}

gboolean ssc_message(const guint8 *buf, gsize len, struct ssc_message *out)
{
	if (len < HEADER || len - HEADER < le16(buf + 5))
		return FALSE;
	out->type = buf[0];
	out->txn = le16(buf + 1);
	out->id = le16(buf + 3);
	out->tlvs = buf + HEADER;
	out->len = le16(buf + 5);
	return TRUE;
}

static gboolean tlv(const struct ssc_message *message, guint8 id, const guint8 **value, gsize *len)
{
	gsize pos = 0;
	while (message->len - pos >= 3) {
		gsize size = le16(message->tlvs + pos + 1);
		if (message->len - pos - 3 < size)
			return FALSE;
		if (message->tlvs[pos] == id) {
			*value = message->tlvs + pos + 3;
			*len = size;
			return TRUE;
		}
		pos += 3 + size;
	}
	return FALSE;
}

gboolean ssc_result(const struct ssc_message *message, guint16 *result, guint16 *error)
{
	const guint8 *value;
	gsize len;

	if (!tlv(message, TLV_DATA, &value, &len) || len < 4)
		return FALSE;
	*result = le16(value);
	*error = le16(value + 2);
	return TRUE;
}

static gboolean parse_suid(const guint8 *data, gsize len, struct ssc_suid *suid)
{
	const guint8 *pos = data, *end = data + len;
	gboolean low = FALSE, high = FALSE;
	struct field field;

	while (next_field(&pos, end, &field)) {
		if (field.wire != FIXED64)
			continue;
		if (field.id == 1) {
			suid->low = field.value;
			low = TRUE;
		} else if (field.id == 2) {
			suid->high = field.value;
			high = TRUE;
		}
	}
	return low && high;
}

gboolean ssc_report(const struct ssc_message *message, struct ssc_suid *suid, ssc_event_func func, void *data)
{
	const guint8 *value, *pos, *end;
	gsize len;
	struct field field;
	gboolean found = FALSE;

	if (!tlv(message, TLV_DATA, &value, &len) || len < 2 || len - 2 < le16(value))
		return FALSE;
	end = value + 2 + le16(value);
	for (pos = value + 2; !found && next_field(&pos, end, &field);)
		found = field.id == 1 && field.wire == BYTES && parse_suid(field.data, field.len, suid);
	if (!found)
		return FALSE;
	for (pos = value + 2; next_field(&pos, end, &field);) {
		const guint8 *epos, *eend;
		struct field inner;
		gboolean known = FALSE;
		guint32 id = 0;
		const guint8 *payload = NULL;
		gsize size = 0;

		if (field.id != 2 || field.wire != BYTES)
			continue;
		epos = field.data;
		eend = field.data + field.len;
		while (next_field(&epos, eend, &inner)) {
			if (inner.id == 1 && inner.wire == FIXED32) {
				id = inner.value;
				known = TRUE;
			} else if (inner.id == 3 && inner.wire == BYTES) {
				payload = inner.data;
				size = inner.len;
			}
		}
		if (known)
			func(id, payload, size, data);
	}
	return TRUE;
}

gint ssc_suid_event(const guint8 *payload, gsize len, const char *type, struct ssc_suid *suid)
{
	const guint8 *pos = payload, *end = payload + len;
	struct field field;
	gboolean matched = FALSE;
	gint count = 0;
	struct ssc_suid one;

	while (next_field(&pos, end, &field)) {
		if (field.wire != BYTES)
			continue;
		if (field.id == 1)
			matched = field.len == strlen(type) && !memcmp(field.data, type, field.len);
		else if (field.id == 2 && parse_suid(field.data, field.len, &one) && count++ == 0)
			*suid = one;
	}
	return matched ? count : -1;
}

guint ssc_floats(const guint8 *payload, gsize len, float *out, guint max, gint *status)
{
	const guint8 *pos = payload, *end = payload + len;
	struct field field;
	guint n = 0;
	guint32 bits;

	*status = 0;
	while (next_field(&pos, end, &field)) {
		if (field.id == 2 && field.wire == VARINT) {
			*status = field.value;
		} else if (field.id == 1 && field.wire == FIXED32) {
			bits = field.value;
			if (n < max)
				memcpy(&out[n++], &bits, sizeof(bits));
		} else if (field.id == 1 && field.wire == BYTES) {
			for (gsize i = 0; i + 4 <= field.len; i += 4) {
				memcpy(&bits, field.data + i, sizeof(bits));
				bits = GUINT32_FROM_LE(bits);
				if (n < max)
					memcpy(&out[n++], &bits, sizeof(bits));
			}
		}
	}
	return n;
}

gboolean ssc_error_code(const guint8 *payload, gsize len, guint64 *code)
{
	const guint8 *pos = payload, *end = payload + len;
	struct field field;

	while (next_field(&pos, end, &field)) {
		if (field.id == 1 && field.wire == VARINT) {
			*code = field.value;
			return TRUE;
		}
	}
	return FALSE;
}
