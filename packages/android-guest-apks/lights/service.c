#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <android/binder_status.h>
#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define TAG "microos_lights"
#define DESCRIPTOR "android.hardware.light.ILights"
#define INTERFACE_HASH "33fec8401b6e66bddaeff251e1a2a0f4fa0d3bee"
#define BACKLIGHT "/data/microos/backlight"
#define BACKLIGHT_TMP BACKLIGHT ".tmp"

enum {
	SET_LIGHT_STATE = FIRST_CALL_TRANSACTION,
	GET_LIGHTS = FIRST_CALL_TRANSACTION + 1,
	GET_INTERFACE_HASH = FIRST_CALL_TRANSACTION + 16777213,
	GET_INTERFACE_VERSION = FIRST_CALL_TRANSACTION + 16777214,
};
enum { INTERFACE_VERSION = 1, PRESENT = 1, LIGHT_ID = 0, LIGHT_ORDINAL = 0, LIGHT_TYPE_BACKLIGHT = 0 };

binder_status_t AServiceManager_addService(AIBinder *binder, const char *instance);
bool ABinderProcess_setThreadPoolMaxThreadCount(uint32_t threads);
void ABinderProcess_joinThreadPool(void);

static void *on_create(void *args)
{
	return args;
}

static void on_destroy(void *data)
{
	(void)data;
}

static void log_errno(const char *step)
{
	__android_log_print(ANDROID_LOG_ERROR, TAG, "%s %s: %s", step, BACKLIGHT_TMP, strerror(errno));
}

static void write_backlight(int brightness)
{
	int fd = open(BACKLIGHT_TMP, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) {
		log_errno("open");
		return;
	}
	if (dprintf(fd, "%d\n", brightness) < 0) {
		log_errno("write");
		close(fd);
		return;
	}
	if (close(fd) != 0) {
		log_errno("close");
		return;
	}
	if (rename(BACKLIGHT_TMP, BACKLIGHT) != 0)
		log_errno("rename");
}

static binder_status_t write_status(AParcel *out, binder_exception_t exception)
{
	AStatus *status = AStatus_fromExceptionCode(exception);
	binder_status_t ret = AParcel_writeStatusHeader(out, status);
	AStatus_delete(status);
	return ret;
}

static binder_status_t read_color(const AParcel *in, int32_t *color)
{
	int32_t present, size;
	binder_status_t ret = AParcel_readInt32(in, &present);
	if (ret != STATUS_OK)
		return ret;
	if (!present)
		return STATUS_UNEXPECTED_NULL;
	ret = AParcel_readInt32(in, &size);
	if (ret != STATUS_OK)
		return ret;
	if (size < 0)
		return STATUS_BAD_VALUE;
	return AParcel_readInt32(in, color);
}

static binder_status_t write_light(AParcel *out, const void *lights, size_t index)
{
	(void)lights;
	(void)index;
	binder_status_t ret = AParcel_writeInt32(out, PRESENT);
	int32_t start = AParcel_getDataPosition(out);
	if (ret == STATUS_OK)
		ret = AParcel_writeInt32(out, 0);
	if (ret == STATUS_OK)
		ret = AParcel_writeInt32(out, LIGHT_ID);
	if (ret == STATUS_OK)
		ret = AParcel_writeInt32(out, LIGHT_ORDINAL);
	if (ret == STATUS_OK)
		ret = AParcel_writeByte(out, LIGHT_TYPE_BACKLIGHT);
	if (ret != STATUS_OK)
		return ret;
	int32_t end = AParcel_getDataPosition(out);
	ret = AParcel_setDataPosition(out, start);
	if (ret == STATUS_OK)
		ret = AParcel_writeInt32(out, end - start);
	if (ret == STATUS_OK)
		ret = AParcel_setDataPosition(out, end);
	return ret;
}

static binder_status_t on_transact(AIBinder *binder, transaction_code_t code, const AParcel *in, AParcel *out)
{
	(void)binder;
	int32_t id, color;
	binder_status_t ret;
	switch (code) {
	case SET_LIGHT_STATE:
		ret = AParcel_readInt32(in, &id);
		if (ret == STATUS_OK)
			ret = read_color(in, &color);
		if (ret != STATUS_OK)
			return ret;
		if (id != LIGHT_ID)
			return write_status(out, EX_UNSUPPORTED_OPERATION);
		write_backlight(color & 0xff);
		return write_status(out, EX_NONE);
	case GET_LIGHTS:
		ret = write_status(out, EX_NONE);
		return ret == STATUS_OK ? AParcel_writeParcelableArray(out, NULL, 1, write_light) : ret;
	case GET_INTERFACE_VERSION:
		ret = write_status(out, EX_NONE);
		return ret == STATUS_OK ? AParcel_writeInt32(out, INTERFACE_VERSION) : ret;
	case GET_INTERFACE_HASH:
		ret = write_status(out, EX_NONE);
		return ret == STATUS_OK ? AParcel_writeString(out, INTERFACE_HASH, sizeof(INTERFACE_HASH) - 1) : ret;
	default:
		return STATUS_UNKNOWN_TRANSACTION;
	}
}

int main(void)
{
	umask(022);
	ABinderProcess_setThreadPoolMaxThreadCount(0);
	AIBinder *binder = AIBinder_new(AIBinder_Class_define(DESCRIPTOR, on_create, on_destroy, on_transact), NULL);
	binder_status_t ret = AServiceManager_addService(binder, DESCRIPTOR "/default");
	if (ret != STATUS_OK) {
		__android_log_print(ANDROID_LOG_ERROR, TAG, "addService %s/default: %d", DESCRIPTOR, ret);
		return 1;
	}
	ABinderProcess_joinThreadPool();
	return 1;
}
