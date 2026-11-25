#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <android/binder_status.h>
#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define TAG "microos_vibrator"
#define DESCRIPTOR "android.hardware.vibrator.IVibrator"
#define INTERFACE_HASH "ea8742d6993e1a82917da38b9938e537aa7fcb54"
#define VIBRATOR "/data/microos/vibrator"
#define VIBRATOR_TMP VIBRATOR ".tmp"

enum {
	GET_CAPABILITIES = FIRST_CALL_TRANSACTION,
	OFF = FIRST_CALL_TRANSACTION + 1,
	ON = FIRST_CALL_TRANSACTION + 2,
	PERFORM = FIRST_CALL_TRANSACTION + 3,
	GET_SUPPORTED_EFFECTS = FIRST_CALL_TRANSACTION + 4,
	SET_AMPLITUDE = FIRST_CALL_TRANSACTION + 5,
	COMPOSE_PWLE = FIRST_CALL_TRANSACTION + 23,
	GET_INTERFACE_HASH = FIRST_CALL_TRANSACTION + 16777213,
	GET_INTERFACE_VERSION = FIRST_CALL_TRANSACTION + 16777214,
};
enum { INTERFACE_VERSION = 2, CAP_AMPLITUDE_CONTROL = 4, MAX_AMPLITUDE = 255 };
enum { CLICK = 0, TICK = 2, HEAVY_CLICK = 5, TEXTURE_TICK = 21 };
enum { LIGHT = 0, MEDIUM = 1, STRONG = 2 };

static const int32_t effects[] = { CLICK, TICK, HEAVY_CLICK, TEXTURE_TICK };
static const int32_t strengths[] = { [LIGHT] = 85, [MEDIUM] = 170, [STRONG] = MAX_AMPLITUDE };
static int32_t amplitude = MAX_AMPLITUDE;
static int64_t until;

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
	__android_log_print(ANDROID_LOG_ERROR, TAG, "%s %s: %s", step, VIBRATOR_TMP, strerror(errno));
}

static void write_vibrator(int32_t ms, int32_t level)
{
	int fd = open(VIBRATOR_TMP, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) {
		log_errno("open");
		return;
	}
	if (dprintf(fd, "%d %d\n", ms, level) < 0) {
		log_errno("write");
		close(fd);
		return;
	}
	if (close(fd) != 0) {
		log_errno("close");
		return;
	}
	if (rename(VIBRATOR_TMP, VIBRATOR) != 0)
		log_errno("rename");
}

static int64_t now_ms(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void play(int32_t ms, int32_t level)
{
	until = now_ms() + ms;
	write_vibrator(ms, level);
}

static int32_t effect_ms(int32_t effect)
{
	switch (effect) {
	case TEXTURE_TICK:
		return 8;
	case TICK:
		return 12;
	case CLICK:
		return 25;
	case HEAVY_CLICK:
		return 50;
	default:
		return 0;
	}
}

static binder_status_t write_status(AParcel *out, binder_exception_t exception)
{
	AStatus *status = AStatus_fromExceptionCode(exception);
	binder_status_t ret = AParcel_writeStatusHeader(out, status);
	AStatus_delete(status);
	return ret;
}

static binder_status_t write_int(AParcel *out, int32_t value)
{
	binder_status_t ret = write_status(out, EX_NONE);
	return ret == STATUS_OK ? AParcel_writeInt32(out, value) : ret;
}

static binder_status_t on_transact(AIBinder *binder, transaction_code_t code, const AParcel *in, AParcel *out)
{
	(void)binder;
	int32_t ms, effect;
	int8_t strength;
	float level;
	int64_t left;
	binder_status_t ret;
	switch (code) {
	case GET_CAPABILITIES:
		return write_int(out, CAP_AMPLITUDE_CONTROL);
	case OFF:
		play(0, 0);
		return write_status(out, EX_NONE);
	case ON:
		ret = AParcel_readInt32(in, &ms);
		if (ret != STATUS_OK)
			return ret;
		if (ms <= 0)
			return write_status(out, EX_ILLEGAL_ARGUMENT);
		play(ms, amplitude);
		return write_status(out, EX_NONE);
	case PERFORM:
		ret = AParcel_readInt32(in, &effect);
		if (ret == STATUS_OK)
			ret = AParcel_readByte(in, &strength);
		if (ret != STATUS_OK)
			return ret;
		ms = effect_ms(effect);
		if (!ms || strength < LIGHT || strength > STRONG)
			return write_status(out, EX_UNSUPPORTED_OPERATION);
		play(ms, strengths[strength]);
		return write_int(out, ms);
	case GET_SUPPORTED_EFFECTS:
		ret = write_status(out, EX_NONE);
		return ret == STATUS_OK ?
			       AParcel_writeInt32Array(out, effects, sizeof(effects) / sizeof(effects[0])) :
			       ret;
	case SET_AMPLITUDE:
		ret = AParcel_readFloat(in, &level);
		if (ret != STATUS_OK)
			return ret;
		if (!(level > 0.0f && level <= 1.0f))
			return write_status(out, EX_ILLEGAL_ARGUMENT);
		amplitude = (int32_t)(level * MAX_AMPLITUDE + 0.5f);
		if (amplitude < 1)
			amplitude = 1;
		left = until - now_ms();
		if (left > 0)
			write_vibrator((int32_t)left, amplitude);
		return write_status(out, EX_NONE);
	case GET_INTERFACE_VERSION:
		return write_int(out, INTERFACE_VERSION);
	case GET_INTERFACE_HASH:
		ret = write_status(out, EX_NONE);
		return ret == STATUS_OK ? AParcel_writeString(out, INTERFACE_HASH, sizeof(INTERFACE_HASH) - 1) : ret;
	default:
		if (code > SET_AMPLITUDE && code <= COMPOSE_PWLE)
			return write_status(out, EX_UNSUPPORTED_OPERATION);
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
