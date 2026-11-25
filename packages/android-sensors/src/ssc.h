#ifndef SSC_H
#define SSC_H

#include <glib.h>

enum { SSC_SERVICE = 400 };
enum { SSC_REQUEST = 0, SSC_RESPONSE = 2, SSC_INDICATION = 4 };
enum { SSC_CONTROL = 0x20, SSC_REPORT_SMALL = 0x21, SSC_REPORT_LARGE = 0x22 };
enum { SSC_ERROR_EVENT = 130, SSC_SUID_EVENT = 768, SSC_SENSOR_EVENT = 1025 };

struct ssc_suid {
	guint64 low;
	guint64 high;
};

struct ssc_message {
	guint8 type;
	guint16 txn;
	guint16 id;
	const guint8 *tlvs;
	gsize len;
};

typedef void (*ssc_event_func)(guint32 id, const guint8 *payload, gsize len, void *data);

extern const struct ssc_suid ssc_lookup;

gboolean ssc_suid_equal(const struct ssc_suid *a, const struct ssc_suid *b);
GByteArray *ssc_suid_request(guint16 txn, const char *type);
GByteArray *ssc_enable_request(guint16 txn, const struct ssc_suid *suid, float rate);
GByteArray *ssc_disable_request(guint16 txn, const struct ssc_suid *suid);
gboolean ssc_message(const guint8 *buf, gsize len, struct ssc_message *out);
gboolean ssc_result(const struct ssc_message *message, guint16 *result, guint16 *error);
gboolean ssc_report(const struct ssc_message *message, struct ssc_suid *suid, ssc_event_func func, void *data);
gint ssc_suid_event(const guint8 *payload, gsize len, const char *type, struct ssc_suid *suid);
guint ssc_floats(const guint8 *payload, gsize len, float *out, guint max, gint *status);
gboolean ssc_error_code(const guint8 *payload, gsize len, guint64 *code);

#endif
