#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <linux/ethtool.h>
#include <linux/sockios.h>
#include <linux/udp.h>
#include <math.h>
#include <net/if.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "pcam_aes_bridge.h"

#define WIDTH 1280U
#define HEIGHT 720U
#define LINE_BYTES (WIDTH * 2U)
#define FRAME_BYTES (LINE_BYTES * HEIGHT)
#define PACKET_COUNT 1280U
#define UDP_RECORD_BYTES 1472U
#define NETWORK_FRAME_BYTES (PACKET_COUNT * UDP_RECORD_BYTES)
#define PACKET_MAGIC 0x5043414dU
#define PROTOCOL_VERSION 1U
#define RECEIVE_BATCH 16U
#define GRO_SEGMENTS 44U
#define RECEIVE_BUFFER_BYTES (UDP_RECORD_BYTES * GRO_SEGMENTS)
#define FRAME_QUEUE_COUNT 4U
#define NORMAL_FRAME_SLOTS (FRAME_QUEUE_COUNT - 1U)
#define REPLAY_FRAME_SLOT (FRAME_QUEUE_COUNT - 1U)
#define TELEMETRY_PROTOCOL_VERSION 2U
#define TELEMETRY_UART_DEFAULT "/dev/ttyPS0"
#define TELEMETRY_UART_BAUD_DEFAULT 115200U
#define TELEMETRY_FRAME_PREFIX "ZYBO_RX_V1"
#define TELEMETRY_PERIOD_MS 200U
#define TELEMETRY_HISTORY_SAMPLES 6U
#define FRAME_ASSEMBLY_TIMEOUT_MS 150U

#define DMA_BASE 0x40400000UL
#define VDMA_BASE 0x43000000UL
#define GPIO_BASE 0x41200000UL
#define ERROR_GPIO_BASE 0x41220000UL
#define SESSION_BASE 0x43d00000UL
#define REGISTER_SPAN 0x10000UL

#define SESSION_REG_ID 0x00U
#define SESSION_REG_CONTROL 0x04U
#define SESSION_REG_STATUS 0x08U
#define SESSION_REG_ACTIVE_ID 0x30U
#define SESSION_REG_MAGIC 0x4b455931U
#define SESSION_STATUS_READY_MASK 0x00000003U
#define SESSION_STATUS_COMMAND_ERROR (1U << 3)
#define SESSION_STATUS_TRANSITION_MASK 0x000001c0U
#define SESSION_STATUS_FRAME_LOCK (1U << 9)
#define SESSION_CONTROL_FRAME_ACQUIRE (1U << 4)
#define SESSION_CONTROL_FRAME_RELEASE (1U << 5)

#define NETWORK_BUFFER_PHYS 0x18000000UL
#define NETWORK_BUFFER_STRIDE 0x00200000UL
#define NETWORK_BUFFER_COUNT 4U
#define NETWORK_BUFFER_SPAN (NETWORK_BUFFER_STRIDE * NETWORK_BUFFER_COUNT)
#define VIDEO_BUFFER0_PHYS 0x19000000UL
#define VIDEO_BUFFER_STRIDE 0x00200000UL
#define VIDEO_BUFFER_COUNT 3U

#define DMA_MM2S_CR 0x00U
#define DMA_MM2S_SR 0x04U
#define DMA_MM2S_SA 0x18U
#define DMA_MM2S_LENGTH 0x28U
#define DMA_S2MM_CR 0x30U
#define DMA_S2MM_SR 0x34U
#define DMA_S2MM_DA 0x48U
#define DMA_S2MM_LENGTH 0x58U
#define DMA_CR_RUNSTOP 0x00000001U
#define DMA_CR_RESET 0x00000004U
#define DMA_SR_IDLE 0x00000002U
#define DMA_SR_ERRORS 0x00000770U

#define VDMA_MM2S_CR 0x00U
#define VDMA_MM2S_SR 0x04U
#define VDMA_PARK_PTR 0x28U
#define VDMA_MM2S_VSIZE 0x50U
#define VDMA_MM2S_HSIZE 0x54U
#define VDMA_MM2S_STRIDE 0x58U
#define VDMA_MM2S_START0 0x5cU
#define VDMA_CR_RUNSTOP 0x00000001U
#define VDMA_CR_RESET 0x00000004U
#define VDMA_SR_ERRORS 0x00000ff0U

#define GPIO_DATA 0x00U
#define GPIO_TRI 0x04U
#define GPIO2_DATA 0x08U
#define GPIO2_TRI 0x0cU
#define ERROR_VIEW_SHIFT 5U
#define ERROR_STICKY(v) (((v) >> 26) & 0x1fU)
#define ERROR_LAST_FLAGS(v) (((v) >> 21) & 0x1fU)
#define ERROR_LAST_CODE(v) (((v) >> 18) & 0x07U)
#define ERROR_OVERFLOW(v) (((v) >> 17) & 0x01U)
#define STATUS_TOGGLE(v) (((v) >> 31) & 1U)
#define STATUS_MODE(v) (((v) >> 30) & 1U)
#define STATUS_FAILED(v) (((v) >> 29) & 1U)
#define STATUS_FRAME16(v) ((uint16_t)((v) & 0xffffU))

static volatile sig_atomic_t stop_requested;
static double dma_submit_seconds;
static double dma_wait_seconds;
static uint64_t dma_call_count;

static void tune_rx_ring(const char *interface_name)
{
    int fd;
    struct ifreq ifr;
    struct ethtool_ringparam ring;

    fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        fprintf(stderr, "warning: RX ring socket: %s\n", strerror(errno));
        return;
    }
    memset(&ifr, 0, sizeof(ifr));
    memset(&ring, 0, sizeof(ring));
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", interface_name);
    ring.cmd = ETHTOOL_GRINGPARAM;
    ifr.ifr_data = (void *)&ring;
    if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
        fprintf(stderr, "warning: query %s RX ring: %s\n",
                interface_name, strerror(errno));
        close(fd);
        return;
    }
    if (ring.rx_max_pending > ring.rx_pending) {
        ring.cmd = ETHTOOL_SRINGPARAM;
        ring.rx_pending = ring.rx_max_pending;
        if (ioctl(fd, SIOCETHTOOL, &ifr) < 0)
            fprintf(stderr, "warning: set %s RX ring to %u: %s\n",
                    interface_name, ring.rx_pending, strerror(errno));
    }
    fprintf(stderr, "%s RX ring %u/%u descriptors\n", interface_name,
            ring.rx_pending, ring.rx_max_pending);
    close(fd);
}

static void tune_available_rx_rings(void)
{
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *item;

    if (getifaddrs(&interfaces) != 0) {
        fprintf(stderr, "warning: enumerate RX interfaces: %s\n",
                strerror(errno));
        return;
    }
    for (item = interfaces; item != NULL; item = item->ifa_next) {
        struct ifaddrs *previous;
        int already_seen = 0;

        if (item->ifa_addr == NULL || item->ifa_addr->sa_family != AF_INET ||
            (item->ifa_flags & IFF_UP) == 0 ||
            (item->ifa_flags & IFF_LOOPBACK) != 0)
            continue;
        for (previous = interfaces; previous != item;
             previous = previous->ifa_next) {
            if (previous->ifa_addr != NULL &&
                previous->ifa_addr->sa_family == AF_INET &&
                strcmp(previous->ifa_name, item->ifa_name) == 0) {
                already_seen = 1;
                break;
            }
        }
        if (!already_seen)
            tune_rx_ring(item->ifa_name);
    }
    freeifaddrs(interfaces);
}

struct packet_receiver {
    uint8_t data[RECEIVE_BATCH][RECEIVE_BUFFER_BYTES];
    struct iovec vectors[RECEIVE_BATCH];
    struct mmsghdr messages[RECEIVE_BATCH];
    unsigned int count;
    unsigned int next;
    size_t offset;
};

struct display_stats {
    uint32_t session;
    uint32_t last_frame;
    uint64_t lost_total;
    unsigned int window_frames;
    double window_started;
    double fps;
    int have_frame;
};

struct freshness_state {
    uint32_t session;
    uint32_t last_frame;
    int have_frame;
};

struct telemetry_totals {
    uint64_t attempts;
    uint64_t processed_frames;
    uint64_t accepted;
    uint64_t auth_rejects;
    uint64_t replay_rejects;
    uint64_t status_failures;
    uint64_t network_losses;
    uint64_t interval_count;
    double interval_sum;
    double interval_square_sum;
    uint32_t session;
};

struct telemetry_snapshot {
    struct telemetry_totals totals;
    uint64_t queue_overruns;
    uint64_t stale_drops;
    double time;
};

struct error_detector_snapshot {
    uint32_t status;
    uint32_t tag_total;
    uint32_t replay_total;
    uint32_t sequence_total;
    uint32_t session_total;
    uint32_t timeout_total;
    uint32_t last_frame_packet;
    uint32_t last_session;
};

struct frame_queue;

struct telemetry_context {
    pthread_mutex_t mutex;
    pthread_mutex_t output_mutex;
    struct telemetry_totals totals;
    struct frame_queue *queue;
    uint64_t sequence;
    uint64_t event_sequence;
    double last_accepted_time;
    uint32_t last_accepted_session;
    volatile uint32_t *error_gpio;
    char uart_device[128];
    unsigned int uart_baud;
    int uart_fd;
    int enabled;
};

static inline uint32_t reg_read(volatile uint32_t *base,
                                unsigned int offset);
static inline void reg_write(volatile uint32_t *base, unsigned int offset,
                             uint32_t value);

static uint32_t error_detector_read_view(volatile uint32_t *gpio,
                                         unsigned int view)
{
    reg_write(gpio, GPIO2_DATA, (view & 7U) << ERROR_VIEW_SHIFT);
    __sync_synchronize();
    return reg_read(gpio, GPIO_DATA);
}

static void error_detector_read(volatile uint32_t *gpio,
                                struct error_detector_snapshot *snapshot)
{
    memset(snapshot, 0, sizeof(*snapshot));
    if (gpio == MAP_FAILED || gpio == NULL)
        return;
    snapshot->status = error_detector_read_view(gpio, 0U);
    snapshot->tag_total = error_detector_read_view(gpio, 1U);
    snapshot->replay_total = error_detector_read_view(gpio, 2U);
    snapshot->sequence_total = error_detector_read_view(gpio, 3U);
    snapshot->session_total = error_detector_read_view(gpio, 4U);
    snapshot->timeout_total = error_detector_read_view(gpio, 5U);
    snapshot->last_frame_packet = error_detector_read_view(gpio, 6U);
    snapshot->last_session = error_detector_read_view(gpio, 7U);
}

enum frame_slot_state {
    SLOT_FREE,
    SLOT_FILLING,
    SLOT_RECEIVED,
    SLOT_COPYING,
    SLOT_READY,
    SLOT_PROCESSING
};

struct frame_slot {
    uint8_t *data;      /* cacheable userspace receive staging */
    uint8_t *dma_data;  /* CMA DMA-BUF consumed by AXI DMA */
    unsigned long physical;
    int dmabuf_fd;
    uint32_t dma_handle;
    uint32_t session;
    uint32_t frame;
    uint64_t serial;
    uint8_t seen[PACKET_COUNT];
    unsigned int received_packets;
    double first_packet_time;
    double last_packet_time;
    int sync_active;
    enum frame_slot_state state;
};

struct frame_queue {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    struct frame_slot slots[FRAME_QUEUE_COUNT];
    uint64_t serial;
    uint64_t overruns;
    uint64_t stale_drops;
    int receiver_failed;
};

struct receiver_context {
    int socket_fd;
    int cma_direct;
    struct frame_queue *queue;
    struct packet_receiver packets;
    uint32_t assembly_session;
    int have_assembly_session;
    uint32_t last_normal_session;
    uint32_t last_normal_frame;
    int have_last_normal;
    uint8_t pending[RECEIVE_BUFFER_BYTES]; /* legacy ordered-GRO fallback */
    size_t pending_length;
    uint64_t sync_frames;
    double sync_seconds;
};

struct copy_context {
    struct frame_queue *queue;
    uint64_t frames;
    double seconds;
    int failed;
};

static void on_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static double monotonic_seconds(void)
{
    struct timespec value;

    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static int freshness_accept(struct freshness_state *state, uint32_t session,
                            uint32_t frame, uint32_t *loss_out)
{
    int32_t distance;

    *loss_out = 0U;
    if (!state->have_frame || state->session != session) {
        state->session = session;
        state->last_frame = frame;
        state->have_frame = 1;
        return 1;
    }
    distance = (int32_t)(frame - state->last_frame);
    if (distance <= 0)
        return 0;
    state->last_frame = frame;
    if ((uint32_t)distance < 100000U)
        *loss_out = (uint32_t)distance - 1U;
    return 1;
}

static int freshness_self_test(void)
{
    struct freshness_state state = {0};
    uint32_t loss = 0U;

    if (!freshness_accept(&state, 7U, UINT32_MAX - 1U, &loss) || loss != 0U ||
        !freshness_accept(&state, 7U, UINT32_MAX, &loss) || loss != 0U ||
        !freshness_accept(&state, 7U, 0U, &loss) || loss != 0U ||
        freshness_accept(&state, 7U, UINT32_MAX, &loss) ||
        !freshness_accept(&state, 7U, 3U, &loss) || loss != 2U ||
        freshness_accept(&state, 7U, 3U, &loss) ||
        !freshness_accept(&state, 8U, 1U, &loss) || loss != 0U) {
        fprintf(stderr, "FAIL: replay freshness serial comparison\n");
        return -1;
    }
    fprintf(stderr, "PASS: replay freshness, wraparound, duplicate rejection, session reset\n");
    return 0;
}

static uint32_t telemetry_crc32(const uint8_t *data, size_t length)
{
    uint32_t crc = UINT32_MAX;

    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned int bit = 0; bit < 8U; ++bit)
            crc = (crc >> 1) ^ (0xedb88320U &
                  (uint32_t)-(int32_t)(crc & 1U));
    }

    return ~crc;
}

static speed_t telemetry_uart_speed(unsigned int baud)
{
    switch (baud) {
    case 9600U: return B9600;
    case 19200U: return B19200;
    case 38400U: return B38400;
    case 57600U: return B57600;
    case 115200U: return B115200;
    default: return (speed_t)0;
    }
}

static int telemetry_uart_open_locked(struct telemetry_context *context)
{
    struct termios settings;
    speed_t speed;
    int fd;

    if (context->uart_fd >= 0)
        return 0;
    speed = telemetry_uart_speed(context->uart_baud);
    if (speed == (speed_t)0) {
        errno = EINVAL;
        return -1;
    }
    fd = open(context->uart_device,
              O_WRONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return -1;
    if (tcgetattr(fd, &settings) < 0) {
        close(fd);
        return -1;
    }
    cfmakeraw(&settings);
    settings.c_cflag &= ~(CSIZE | PARENB | CSTOPB | CRTSCTS);
    settings.c_cflag |= CS8 | CLOCAL | CREAD;
    if (cfsetispeed(&settings, speed) < 0 ||
        cfsetospeed(&settings, speed) < 0 ||
        tcsetattr(fd, TCSANOW, &settings) < 0) {
        close(fd);
        return -1;
    }
    context->uart_fd = fd;
    return 0;
}

static void telemetry_uart_close_locked(struct telemetry_context *context)
{
    if (context->uart_fd >= 0)
        close(context->uart_fd);
    context->uart_fd = -1;
}

static int telemetry_uart_send(struct telemetry_context *context, char kind,
                               const char *message, size_t length)
{
    char frame[1536];
    uint32_t crc = telemetry_crc32((const uint8_t *)message, length);
    int frame_length = snprintf(frame, sizeof(frame), "%s %c %08x %.*s\n",
                                TELEMETRY_FRAME_PREFIX, kind, crc,
                                (int)length, message);
    size_t offset = 0U;
    int result = -1;

    if (frame_length <= 0 || (size_t)frame_length >= sizeof(frame))
        return -1;
    pthread_mutex_lock(&context->output_mutex);
    if (telemetry_uart_open_locked(context) < 0)
        goto out;
    while (offset < (size_t)frame_length) {
        ssize_t written = write(context->uart_fd, frame + offset,
                                (size_t)frame_length - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        telemetry_uart_close_locked(context);
        goto out;
    }
    result = 0;
out:
    pthread_mutex_unlock(&context->output_mutex);
    return result;
}

static int telemetry_init(struct telemetry_context *context,
                          struct frame_queue *queue, const char *uart_device,
                          unsigned int uart_baud,
                          volatile uint32_t *error_gpio)
{
    memset(context, 0, sizeof(*context));
    context->uart_fd = -1;
    if (pthread_mutex_init(&context->mutex, NULL) != 0)
        return -1;
    if (pthread_mutex_init(&context->output_mutex, NULL) != 0) {
        pthread_mutex_destroy(&context->mutex);
        return -1;
    }
    context->queue = queue;
    context->error_gpio = error_gpio;
    if (uart_device == NULL || *uart_device == '\0' ||
        strcmp(uart_device, "off") == 0) {
        fprintf(stderr, "RX PC UART telemetry disabled\n");
        return 0;
    }
    if (strlen(uart_device) >= sizeof(context->uart_device) ||
        telemetry_uart_speed(uart_baud) == (speed_t)0) {
        fprintf(stderr, "invalid RX telemetry UART %s at %u baud\n",
                uart_device, uart_baud);
        pthread_mutex_destroy(&context->output_mutex);
        pthread_mutex_destroy(&context->mutex);
        return -1;
    }
    snprintf(context->uart_device, sizeof(context->uart_device), "%s",
             uart_device);
    context->uart_baud = uart_baud;
    context->enabled = 1;
    fprintf(stderr,
            "RX -> PC telemetry/events 5 Hz framed UART -> %s at %u baud\n",
            context->uart_device, context->uart_baud);
    fprintf(stderr,
            "UART output is gated until an authenticated session is active\n");
    return 0;
}

static void telemetry_destroy(struct telemetry_context *context)
{
    pthread_mutex_lock(&context->output_mutex);
    telemetry_uart_close_locked(context);
    pthread_mutex_unlock(&context->output_mutex);
    pthread_mutex_destroy(&context->output_mutex);
    pthread_mutex_destroy(&context->mutex);
}

static void security_event_send(struct telemetry_context *context,
                                const char *event_type, uint32_t session,
                                uint32_t frame, uint32_t last_accepted_frame,
                                int include_last_accepted)
{
    char message[320];
    int length;
    if (!context->enabled || session == 0U)
        return;
    ++context->event_sequence;
    if (include_last_accepted) {
        length = snprintf(
            message, sizeof(message),
            "{\"protocol_version\":%u,\"source_role\":\"zybo-rx\","
            "\"transport\":\"uart\",\"event_seq\":%llu,"
            "\"monotonic_ms\":%llu,\"event_type\":\"%s\","
            "\"session_id\":\"0x%08x\",\"frame_id\":%u,"
            "\"last_accepted_frame_id\":%u}",
            TELEMETRY_PROTOCOL_VERSION,
            (unsigned long long)context->event_sequence,
            (unsigned long long)(monotonic_seconds() * 1000.0), event_type,
            session, frame, last_accepted_frame);
    } else {
        length = snprintf(
            message, sizeof(message),
            "{\"protocol_version\":%u,\"source_role\":\"zybo-rx\","
            "\"transport\":\"uart\",\"event_seq\":%llu,"
            "\"monotonic_ms\":%llu,\"event_type\":\"%s\","
            "\"session_id\":\"0x%08x\",\"frame_id\":%u}",
            TELEMETRY_PROTOCOL_VERSION,
            (unsigned long long)context->event_sequence,
            (unsigned long long)(monotonic_seconds() * 1000.0), event_type,
            session, frame);
    }
    if (length <= 0 || (size_t)length >= sizeof(message))
        return;
    (void)telemetry_uart_send(context, 'E', message, (size_t)length);
}

static void telemetry_status_failure(struct telemetry_context *context)
{
    pthread_mutex_lock(&context->mutex);
    ++context->totals.processed_frames;
    ++context->totals.status_failures;
    pthread_mutex_unlock(&context->mutex);
}

static void telemetry_attempt(struct telemetry_context *context,
                              uint32_t session)
{
    pthread_mutex_lock(&context->mutex);
    ++context->totals.attempts;
    context->totals.session = session;
    pthread_mutex_unlock(&context->mutex);
}

static void telemetry_auth_reject(struct telemetry_context *context)
{
    pthread_mutex_lock(&context->mutex);
    ++context->totals.processed_frames;
    ++context->totals.auth_rejects;
    pthread_mutex_unlock(&context->mutex);
}

static void telemetry_replay_reject(struct telemetry_context *context)
{
    pthread_mutex_lock(&context->mutex);
    ++context->totals.processed_frames;
    ++context->totals.replay_rejects;
    pthread_mutex_unlock(&context->mutex);
}

static void telemetry_accept(struct telemetry_context *context,
                             uint32_t session, uint32_t network_loss)
{
    const double now = monotonic_seconds();

    pthread_mutex_lock(&context->mutex);
    ++context->totals.processed_frames;
    ++context->totals.accepted;
    context->totals.network_losses += network_loss;
    context->totals.session = session;
    if (context->last_accepted_time != 0.0 &&
        context->last_accepted_session == session) {
        const double interval = now - context->last_accepted_time;
        ++context->totals.interval_count;
        context->totals.interval_sum += interval;
        context->totals.interval_square_sum += interval * interval;
    }
    context->last_accepted_time = now;
    context->last_accepted_session = session;
    pthread_mutex_unlock(&context->mutex);
}

static uint64_t delta_u64(uint64_t current, uint64_t previous)
{
    return current >= previous ? current - previous : 0U;
}

static void *telemetry_worker(void *opaque)
{
    struct telemetry_context *context = opaque;
    struct telemetry_snapshot history[TELEMETRY_HISTORY_SAMPLES] = {0};
    struct telemetry_snapshot previous = {0};
    unsigned int next = 0U, count = 0U;
    int have_previous = 0;
    int warned = 0;

    while (!stop_requested) {
        struct timespec delay = {0, TELEMETRY_PERIOD_MS * 1000000L};
        struct telemetry_snapshot current;
        const struct telemetry_snapshot *oldest;
        double window, valid_fps, attempt_fps, auth_rate, replay_rate;
        double drop_ratio = 0.0, jitter_ms = 0.0;
        uint64_t accepted, processed, auth, replay, loss_window, intervals;
        uint64_t network_loss_delta, queue_overrun, stale, status_failure;
        uint64_t sequence;
        struct error_detector_snapshot detector;
        char message[1280];
        int length;

        while (nanosleep(&delay, &delay) != 0 && errno == EINTR &&
               !stop_requested)
            ;
        if (stop_requested)
            break;
        memset(&current, 0, sizeof(current));
        current.time = monotonic_seconds();
        pthread_mutex_lock(&context->mutex);
        current.totals = context->totals;
        sequence = ++context->sequence;
        pthread_mutex_unlock(&context->mutex);
        pthread_mutex_lock(&context->queue->mutex);
        current.queue_overruns = context->queue->overruns;
        current.stale_drops = context->queue->stale_drops;
        pthread_mutex_unlock(&context->queue->mutex);

        history[next] = current;
        next = (next + 1U) % TELEMETRY_HISTORY_SAMPLES;
        if (count < TELEMETRY_HISTORY_SAMPLES)
            ++count;
        oldest = count == TELEMETRY_HISTORY_SAMPLES ? &history[next] :
                                                     &history[0];
        window = current.time - oldest->time;
        if (!have_previous) {
            previous = current;
            have_previous = 1;
            continue;
        }
        network_loss_delta = delta_u64(current.totals.network_losses,
                                       previous.totals.network_losses);
        queue_overrun = delta_u64(current.queue_overruns,
                                  previous.queue_overruns);
        stale = delta_u64(current.stale_drops, previous.stale_drops);
        status_failure = delta_u64(current.totals.status_failures,
                                   previous.totals.status_failures);
        previous = current;
        /* totals.session becomes non-zero only after the RX PL session bank
         * matches an authenticated packet session.  This keeps UART silent
         * through boot, Wi-Fi association, and ECDH key exchange. */
        if (!context->enabled || current.totals.session == 0U ||
            window <= 0.0)
            continue;

        error_detector_read(context->error_gpio, &detector);

        accepted = delta_u64(current.totals.accepted,
                             oldest->totals.accepted);
        processed = delta_u64(current.totals.processed_frames,
                              oldest->totals.processed_frames);
        auth = delta_u64(current.totals.auth_rejects,
                         oldest->totals.auth_rejects);
        replay = delta_u64(current.totals.replay_rejects,
                           oldest->totals.replay_rejects);
        loss_window = delta_u64(current.totals.network_losses,
                                oldest->totals.network_losses);
        intervals = delta_u64(current.totals.interval_count,
                              oldest->totals.interval_count);
        valid_fps = accepted / window;
        attempt_fps = processed / window;
        auth_rate = auth / window;
        replay_rate = replay / window;
        if (accepted + loss_window != 0U)
            drop_ratio = (double)loss_window /
                         (double)(accepted + loss_window);
        if (intervals != 0U) {
            const double sum = current.totals.interval_sum -
                               oldest->totals.interval_sum;
            const double square_sum = current.totals.interval_square_sum -
                                      oldest->totals.interval_square_sum;
            const double mean = sum / intervals;
            double variance = square_sum / intervals - mean * mean;

            if (variance < 0.0)
                variance = 0.0;
            jitter_ms = sqrt(variance) * 1000.0;
        }
        length = snprintf(
            message, sizeof(message),
            "{\"protocol_version\":%u,\"source_role\":\"zybo-rx\","
            "\"transport\":\"uart\",\"seq\":%llu,\"monotonic_ms\":%llu,"
            "\"session_id\":\"0x%08x\",\"valid_frame_rate\":%.3f,"
            "\"frame_attempt_rate\":%.3f,\"auth_reject_rate\":%.3f,"
            "\"replay_reject_rate\":%.3f,\"frame_drop_ratio\":%.6f,"
            "\"frame_jitter_ms\":%.3f,\"network_loss_delta\":%llu,"
            "\"queue_overrun_delta\":%llu,"
            "\"stale_drop_delta\":%llu,\"status_failure_delta\":%llu,"
            "\"processed_frames_total\":%llu,"
            "\"authentication_failures_total\":%llu,"
            "\"replay_reject_total\":%llu,"
            "\"detector_status\":%u,\"detector_sticky\":%u,"
            "\"detector_last_flags\":%u,\"detector_last_code\":%u,"
            "\"detector_overflow\":%u,\"detector_tag_total\":%u,"
            "\"detector_replay_total\":%u,"
            "\"detector_sequence_total\":%u,"
            "\"detector_session_total\":%u,"
            "\"detector_timeout_total\":%u,"
            "\"detector_last_frame16\":%u,"
            "\"detector_last_packet\":%u,"
            "\"detector_last_session\":\"0x%08x\"}",
            TELEMETRY_PROTOCOL_VERSION,
            (unsigned long long)sequence,
            (unsigned long long)(current.time * 1000.0),
            current.totals.session, valid_fps, attempt_fps, auth_rate,
            replay_rate, drop_ratio, jitter_ms,
            (unsigned long long)network_loss_delta,
            (unsigned long long)queue_overrun, (unsigned long long)stale,
            (unsigned long long)status_failure,
            (unsigned long long)current.totals.processed_frames,
            (unsigned long long)current.totals.auth_rejects,
            (unsigned long long)current.totals.replay_rejects,
            detector.status, ERROR_STICKY(detector.status),
            ERROR_LAST_FLAGS(detector.status), ERROR_LAST_CODE(detector.status),
            ERROR_OVERFLOW(detector.status), detector.tag_total,
            detector.replay_total, detector.sequence_total,
            detector.session_total, detector.timeout_total,
            detector.last_frame_packet >> 16,
            detector.last_frame_packet & 0xffffU, detector.last_session);
        if (length <= 0 || (size_t)length >= sizeof(message))
            continue;
        if (telemetry_uart_send(context, 'T', message, (size_t)length) < 0 &&
            !warned) {
            fprintf(stderr, "RX telemetry UART unavailable: %s\n",
                    strerror(errno));
            warned = 1;
        } else if (context->uart_fd >= 0) {
            warned = 0;
        }
    }
    return NULL;
}

static void receiver_init(struct packet_receiver *receiver)
{
    memset(receiver, 0, sizeof(*receiver));
    for (unsigned int i = 0; i < RECEIVE_BATCH; ++i) {
        receiver->vectors[i].iov_base = receiver->data[i];
        receiver->vectors[i].iov_len = RECEIVE_BUFFER_BYTES;
        receiver->messages[i].msg_hdr.msg_iov = &receiver->vectors[i];
        receiver->messages[i].msg_hdr.msg_iovlen = 1;
    }
}

static int receiver_next(int socket_fd, struct packet_receiver *receiver,
                         const uint8_t **packet, size_t *length)
{
    for (;;) {
        if (receiver->next < receiver->count) {
            size_t message_length = receiver->messages[receiver->next].msg_len;
            size_t remaining = message_length - receiver->offset;

            *packet = receiver->data[receiver->next] + receiver->offset;
            *length = remaining < UDP_RECORD_BYTES ?
                      remaining : UDP_RECORD_BYTES;
            receiver->offset += *length;
            if (receiver->offset == message_length) {
                ++receiver->next;
                receiver->offset = 0U;
            }
            return 0;
        }

        {
        int received;

        for (unsigned int i = 0; i < RECEIVE_BATCH; ++i) {
            receiver->messages[i].msg_len = 0;
            receiver->messages[i].msg_hdr.msg_flags = 0;
        }
        do {
            received = recvmmsg(socket_fd, receiver->messages, RECEIVE_BATCH,
                                MSG_WAITFORONE | MSG_TRUNC, NULL);
        } while (received < 0 && errno == EINTR && !stop_requested);
        if (received < 0)
            return -1;
        receiver->count = (unsigned int)received;
        receiver->next = 0U;
        receiver->offset = 0U;
        }
    }
}

static uint32_t load_be32(const uint8_t *data)
{
    uint32_t value;
    memcpy(&value, data, sizeof(value));
    return ntohl(value);
}

static uint16_t load_be16(const uint8_t *data)
{
    uint16_t value;
    memcpy(&value, data, sizeof(value));
    return ntohs(value);
}

struct glyph {
    char character;
    uint8_t rows[7];
};

static uint8_t glyph_row(char character, unsigned int row)
{
    static const struct glyph font[] = {
        {'0', {0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e}},
        {'1', {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e}},
        {'2', {0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f}},
        {'3', {0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e}},
        {'4', {0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02}},
        {'5', {0x1f, 0x10, 0x10, 0x1e, 0x01, 0x01, 0x1e}},
        {'6', {0x0e, 0x10, 0x10, 0x1e, 0x11, 0x11, 0x0e}},
        {'7', {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
        {'8', {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e}},
        {'9', {0x0e, 0x11, 0x11, 0x0f, 0x01, 0x01, 0x0e}},
        {'A', {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
        {'D', {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}},
        {'F', {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10}},
        {'L', {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f}},
        {'O', {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
        {'P', {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10}},
        {'S', {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}},
        {'T', {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}},
        {'U', {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
        {'V', {0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04}},
        {'X', {0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11}},
        {'Y', {0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04}},
        {'.', {0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x0c}}
    };

    for (unsigned int i = 0; i < sizeof(font) / sizeof(font[0]); ++i) {
        if (font[i].character == character)
            return font[i].rows[row];
    }
    return 0U;
}

static void set_yuyv_pixel(uint8_t *frame, size_t stride,
                           unsigned int x, unsigned int y,
                           uint8_t luminance, uint8_t chroma_u,
                           uint8_t chroma_v)
{
    uint8_t *pair = frame + (size_t)y * stride + (x & ~1U) * 2U;

    pair[(x & 1U) ? 2U : 0U] = luminance;
    pair[1] = chroma_u;
    pair[3] = chroma_v;
}

static void draw_overlay(uint8_t *frame, double fps, uint64_t lost_total)
{
    static uint8_t overlay[30U * LINE_BYTES];
    char text[96];
    size_t length;
    unsigned int box_width;
    unsigned int overlay_width;
    size_t overlay_stride;

    snprintf(text, sizeof(text),
             "1280X720 YUYV UDP  %4.1f FPS  LOST TOTAL %llu",
             fps, (unsigned long long)lost_total);
    length = strlen(text);
    box_width = 16U + (unsigned int)length * 12U;
    if (box_width > WIDTH)
        box_width = WIDTH;
    box_width &= ~1U;
    overlay_width = box_width - 8U;
    overlay_stride = (size_t)overlay_width * 2U;

    for (unsigned int y = 0U; y < 30U; ++y) {
        for (unsigned int x = 0U; x + 1U < overlay_width; x += 2U) {
            uint8_t *pair = overlay + (size_t)y * overlay_stride + x * 2U;
            pair[0] = 16U;
            pair[1] = 128U;
            pair[2] = 16U;
            pair[3] = 128U;
        }
    }

    for (size_t character = 0; character < length; ++character) {
        unsigned int origin_x = 8U + (unsigned int)character * 12U;
        for (unsigned int row = 0; row < 7U; ++row) {
            uint8_t bits = glyph_row(text[character], row);
            for (unsigned int column = 0; column < 5U; ++column) {
                if (!(bits & (1U << (4U - column))))
                    continue;
                for (unsigned int dy = 0; dy < 2U; ++dy) {
                    for (unsigned int dx = 0; dx < 2U; ++dx) {
                        set_yuyv_pixel(overlay, overlay_stride,
                                       origin_x + column * 2U + dx,
                                       8U + row * 2U + dy,
                                       145U, 54U, 34U);
                    }
                }
            }
        }
    }

    for (unsigned int y = 0U; y < 30U; ++y)
        memcpy(frame + (size_t)(12U + y) * LINE_BYTES + 8U * 2U,
               overlay + (size_t)y * overlay_stride, overlay_stride);
}

static void update_stats(struct display_stats *stats, uint32_t session,
                         uint32_t frame)
{
    double now = monotonic_seconds();

    if (stats->have_frame && stats->session == session) {
        uint32_t distance = frame - stats->last_frame;
        if (distance > 1U && distance < 100000U)
            stats->lost_total += distance - 1U;
    }
    stats->session = session;
    stats->last_frame = frame;
    stats->have_frame = 1;

    if (stats->window_started == 0.0)
        stats->window_started = now;
    ++stats->window_frames;
    if (now - stats->window_started >= 1.0) {
        stats->fps = stats->window_frames / (now - stats->window_started);
        fprintf(stderr, "STATS 1280x720 YUYV UDP %.1f fps lost total %llu\n",
                stats->fps, (unsigned long long)stats->lost_total);
        stats->window_frames = 0U;
        stats->window_started = now;
    }
}

static inline uint32_t reg_read(volatile uint32_t *base, unsigned int offset)
{
    uint32_t value = base[offset / 4U];
    __sync_synchronize();
    return value;
}

static inline void reg_write(volatile uint32_t *base, unsigned int offset,
                             uint32_t value)
{
    base[offset / 4U] = value;
    __sync_synchronize();
}

/* Reserve one complete RX frame in the PL session controller before starting
 * AXI DMA.  Key clear/commit may be requested while the reservation is held,
 * but PL applies it only after RELEASE, so the DMA cannot lose key_ready in
 * the status-check-to-first-TVALID interval. */
static int acquire_session_frame(volatile uint32_t *regs)
{
    reg_write(regs, SESSION_REG_CONTROL, SESSION_CONTROL_FRAME_ACQUIRE);
    for (unsigned int retry = 0; retry < 1000U; ++retry) {
        uint32_t status = reg_read(regs, SESSION_REG_STATUS);

        if ((status & SESSION_STATUS_COMMAND_ERROR) != 0U) {
            if (status & SESSION_STATUS_FRAME_LOCK)
                reg_write(regs, SESSION_REG_CONTROL,
                          SESSION_CONTROL_FRAME_RELEASE);
            errno = EBUSY;
            return -1;
        }
        if ((status & SESSION_STATUS_TRANSITION_MASK) != 0U ||
            (status & SESSION_STATUS_READY_MASK) !=
                SESSION_STATUS_READY_MASK) {
            if (status & SESSION_STATUS_FRAME_LOCK)
                reg_write(regs, SESSION_REG_CONTROL,
                          SESSION_CONTROL_FRAME_RELEASE);
            errno = EAGAIN;
            return -1;
        }
        if (status & SESSION_STATUS_FRAME_LOCK)
            return 0;
    }
    errno = ETIMEDOUT;
    return -1;
}

static int release_session_frame(volatile uint32_t *regs)
{
    reg_write(regs, SESSION_REG_CONTROL, SESSION_CONTROL_FRAME_RELEASE);
    for (unsigned int retry = 0; retry < 1000U; ++retry) {
        if ((reg_read(regs, SESSION_REG_STATUS) &
             SESSION_STATUS_FRAME_LOCK) == 0U)
            return 0;
    }
    errno = ETIMEDOUT;
    return -1;
}

static void *map_physical(int mem_fd, unsigned long address, size_t length)
{
    void *mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED,
                         mem_fd, (off_t)address);
    if (mapping == MAP_FAILED)
        fprintf(stderr, "mmap 0x%08lx: %s\n", address, strerror(errno));
    return mapping;
}

static int wait_reset_clear(volatile uint32_t *base, unsigned int offset)
{
    for (unsigned int retry = 0; retry < 100000U; ++retry) {
        if ((reg_read(base, offset) & DMA_CR_RESET) == 0U)
            return 0;
    }
    return -1;
}

static int reset_dma(volatile uint32_t *dma)
{
    reg_write(dma, DMA_MM2S_CR, DMA_CR_RESET);
    reg_write(dma, DMA_S2MM_CR, DMA_CR_RESET);
    if (wait_reset_clear(dma, DMA_MM2S_CR) < 0 ||
        wait_reset_clear(dma, DMA_S2MM_CR) < 0) {
        fprintf(stderr, "AXI DMA reset timeout\n");
        return -1;
    }
    return 0;
}

static int open_cma_heap(void)
{
    static const char *const candidates[] = {
        "/dev/dma_heap/reserved",
        "/dev/dma_heap/default_cma_region",
        "/dev/dma_heap/linux,cma",
        "/dev/dma_heap/linux_cma",
        "/dev/dma_heap/cma",
    };

    for (size_t index = 0;
         index < sizeof(candidates) / sizeof(candidates[0]); ++index) {
        int fd = open(candidates[index], O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            fprintf(stderr, "DMA heap %s\n", candidates[index]);
            return fd;
        }
    }
    fprintf(stderr, "no physically contiguous CMA DMA heap found\n");
    return -1;
}

static int allocate_dmabuf(int heap_fd, size_t bytes)
{
    struct dma_heap_allocation_data allocation = {
        .len = bytes,
        .fd_flags = O_RDWR | O_CLOEXEC,
    };

    if (ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &allocation) < 0)
        return -1;
    return (int)allocation.fd;
}

static int sync_dmabuf(int dmabuf_fd, uint64_t flags)
{
    struct dma_buf_sync sync = {.flags = flags};
    int result;

    do {
        result = ioctl(dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync);
    } while (result < 0 && errno == EINTR);
    return result;
}

static int import_dmabuf(int bridge_fd, int dmabuf_fd, uint32_t direction,
                         uint32_t *handle, uint32_t *dma_address)
{
    struct pcam_aes_import request = {
        .dmabuf_fd = dmabuf_fd,
        .direction = direction,
    };

    if (ioctl(bridge_fd, PCAM_AES_IOC_IMPORT, &request) < 0)
        return -1;
    *handle = request.handle;
    *dma_address = request.reserved;
    return 0;
}

static int run_frame_dma(int bridge_fd, uint32_t input_handle,
                         uint32_t output_handle)
{
    const struct pcam_aes_start start = {
        .input_handle = input_handle,
        .output_handle = output_handle,
        .transfer_bytes = NETWORK_FRAME_BYTES,
        .flags = FRAME_BYTES,
    };
    struct pcam_aes_wait wait = {.timeout_ms = 100U};
    double started;

    started = monotonic_seconds();
    if (ioctl(bridge_fd, PCAM_AES_IOC_START, &start) < 0)
        return -1;
    dma_submit_seconds += monotonic_seconds() - started;
    started = monotonic_seconds();
    if (ioctl(bridge_fd, PCAM_AES_IOC_WAIT, &wait) < 0)
        return -1;
    dma_wait_seconds += monotonic_seconds() - started;
    ++dma_call_count;
    if (wait.status) {
        fprintf(stderr,
                "DMAengine status=%d MM2S=%u S2MM=%u\n",
                wait.status, wait.tx_status, wait.rx_status);
        errno = -wait.status;
        return -1;
    }
    return 0;
}

static int start_vdma(volatile uint32_t *vdma,
                      const uint32_t video_addresses[VIDEO_BUFFER_COUNT])
{
    reg_write(vdma, VDMA_MM2S_CR, VDMA_CR_RESET);
    if (wait_reset_clear(vdma, VDMA_MM2S_CR) < 0) {
        fprintf(stderr, "AXI VDMA reset timeout\n");
        return -1;
    }

    for (unsigned int index = 0; index < VIDEO_BUFFER_COUNT; ++index)
        reg_write(vdma, VDMA_MM2S_START0 + index * 4U,
                  video_addresses[index]);
    reg_write(vdma, VDMA_PARK_PTR, 0U);
    reg_write(vdma, VDMA_MM2S_STRIDE, LINE_BYTES);
    reg_write(vdma, VDMA_MM2S_HSIZE, LINE_BYTES);
    reg_write(vdma, VDMA_MM2S_CR, VDMA_CR_RUNSTOP);
    reg_write(vdma, VDMA_MM2S_VSIZE, HEIGHT);

    if (reg_read(vdma, VDMA_MM2S_SR) & VDMA_SR_ERRORS) {
        fprintf(stderr, "AXI VDMA start error 0x%08x\n",
                reg_read(vdma, VDMA_MM2S_SR));
        return -1;
    }
    return 0;
}

static int wait_frame_status(volatile uint32_t *gpio, uint32_t previous,
                             uint32_t *status_out)
{
    const struct timespec pause_time = {0, 100000};
    for (unsigned int retry = 0; retry < 1000U; ++retry) {
        uint32_t status = reg_read(gpio, GPIO_DATA);
        if (STATUS_TOGGLE(status) != STATUS_TOGGLE(previous)) {
            *status_out = status;
            return 0;
        }
        nanosleep(&pause_time, NULL);
    }
    return -1;
}

static int packet_header_valid(const uint8_t *packet, uint32_t session,
                               uint32_t frame, uint16_t index)
{
    uint16_t flags = load_be16(packet + 14U);
    return load_be32(packet) == PACKET_MAGIC &&
           load_be32(packet + 4U) == session &&
           load_be32(packet + 8U) == frame &&
           load_be16(packet + 12U) == index &&
           (flags >> 12) == PROTOCOL_VERSION &&
           (flags & 0x0ff8U) == 0U &&
           (((flags >> 1) & 1U) == (index == 0U)) &&
           (((flags >> 2) & 1U) == (index + 1U == PACKET_COUNT));
}

static int persist_runtime_tx_peer(const struct sockaddr_in *peer)
{
    const char *path = getenv("PCAM_TX_PEER_FILE");
    char address[INET_ADDRSTRLEN + 2U];
    int fd;
    int length;

    if (path == NULL || *path == '\0')
        path = "/run/aes-gcm-tx-peer";
    if (inet_ntop(AF_INET, &peer->sin_addr, address, sizeof(address)) == NULL)
        return -1;
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
              0600);
    if (fd < 0)
        return -1;
    length = snprintf(address + strlen(address),
                      sizeof(address) - strlen(address), "\n");
    if (length <= 0 || write(fd, address, strlen(address)) !=
                           (ssize_t)strlen(address)) {
        close(fd);
        return -1;
    }
    return close(fd);
}

static int video_discovery_interface_usable(const struct ifaddrs *item)
{
    return item->ifa_addr != NULL && item->ifa_broadaddr != NULL &&
           item->ifa_addr->sa_family == AF_INET &&
           item->ifa_broadaddr->sa_family == AF_INET &&
           (item->ifa_flags & (IFF_UP | IFF_BROADCAST)) ==
               (IFF_UP | IFF_BROADCAST) &&
           (item->ifa_flags & IFF_LOOPBACK) == 0;
}

static int interface_is_wireless(const char *interface)
{
    char path[256];
    int length;

    if (interface == NULL || *interface == '\0')
        return 0;
    length = snprintf(path, sizeof(path), "/sys/class/net/%s/wireless",
                      interface);
    return length > 0 && (size_t)length < sizeof(path) &&
           access(path, F_OK) == 0;
}

static void announce_video_receiver(int socket_fd, unsigned int port)
{
    static const char hello[] = "PCAM-GCM-RX";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *item;
    int wired_available = 0;
    int one = 1;

    (void)setsockopt(socket_fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    if (getifaddrs(&interfaces) != 0)
        return;
    for (item = interfaces; item != NULL; item = item->ifa_next) {
        if (video_discovery_interface_usable(item) &&
            !interface_is_wireless(item->ifa_name)) {
            wired_available = 1;
            break;
        }
    }
    for (item = interfaces; item != NULL; item = item->ifa_next) {
        struct sockaddr_in target;

        if (!video_discovery_interface_usable(item) ||
            (wired_available && interface_is_wireless(item->ifa_name)))
            continue;
        if (wired_available && item->ifa_netmask != NULL &&
            item->ifa_netmask->sa_family == AF_INET) {
            const struct sockaddr_in *local =
                (const struct sockaddr_in *)item->ifa_addr;
            const struct sockaddr_in *netmask =
                (const struct sockaddr_in *)item->ifa_netmask;
            const uint32_t local_address = ntohl(local->sin_addr.s_addr);
            uint32_t mask = ntohl(netmask->sin_addr.s_addr);
            uint32_t network = local_address & mask;
            uint32_t broadcast = network | ~mask;
            uint32_t candidate;

            /* Keep discovery bounded even if a lab interface uses a prefix
             * wider than /24.  The range is derived at runtime and never
             * embeds either board's address.  Unicast avoids bridges/APs that
             * suppress directed broadcast and avoids receiving our own hello. */
            if (broadcast - network > 255U) {
                mask = 0xffffff00U;
                network = local_address & mask;
                broadcast = network | ~mask;
            }
            target.sin_family = AF_INET;
            target.sin_port = htons((uint16_t)port);
            for (candidate = network + 1U; candidate < broadcast;
                 ++candidate) {
                if (candidate == local_address)
                    continue;
                target.sin_addr.s_addr = htonl(candidate);
                (void)sendto(socket_fd, hello, sizeof(hello) - 1U,
                             MSG_DONTWAIT, (struct sockaddr *)&target,
                             sizeof(target));
            }
            continue;
        }
        target = *(const struct sockaddr_in *)item->ifa_broadaddr;
        target.sin_port = htons((uint16_t)port);
        (void)sendto(socket_fd, hello, sizeof(hello) - 1U, MSG_DONTWAIT,
                     (struct sockaddr *)&target, sizeof(target));
    }
    freeifaddrs(interfaces);
}

static int discover_video_sender(int socket_fd, unsigned int port,
                                 struct sockaddr_in *peer)
{
    uint8_t probe[64];

    while (!stop_requested) {
        socklen_t peer_length = sizeof(*peer);
        ssize_t received;

        announce_video_receiver(socket_fd, port);
        memset(peer, 0, sizeof(*peer));
        received = recvfrom(socket_fd, probe, sizeof(probe),
                            MSG_PEEK | MSG_TRUNC,
                            (struct sockaddr *)peer, &peer_length);
        if (received >= 16 && load_be32(probe) == PACKET_MAGIC &&
            (load_be16(probe + 14U) >> 12) == PROTOCOL_VERSION) {
            if (connect(socket_fd, (struct sockaddr *)peer,
                        sizeof(*peer)) == 0) {
                (void)persist_runtime_tx_peer(peer);
                return 0;
            }
        } else if (received >= 0) {
            /* Drain our own broadcast or unrelated traffic while preserving
             * the first authenticated-video candidate for the RX worker. */
            (void)recvfrom(socket_fd, probe, sizeof(probe), MSG_TRUNC,
                           NULL, NULL);
        } else if (errno != EAGAIN && errno != EWOULDBLOCK &&
                   errno != EINTR) {
            return -1;
        }
    }
    errno = EINTR;
    return -1;
}

static int __attribute__((unused))
receive_frame(int socket_fd, struct packet_receiver *receiver,
                         uint8_t *network_buffer, uint8_t *seen,
                         uint32_t *session_out, uint32_t *frame_out)
{
    uint32_t session = 0U, frame = 0U;
    unsigned int received = 0U;
    int active = 0;

    memset(seen, 0, PACKET_COUNT);
    while (!stop_requested && received != PACKET_COUNT) {
        const uint8_t *packet;
        size_t length;

        if (receiver_next(socket_fd, receiver, &packet, &length) < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK ||
                errno == ECONNREFUSED) {
                fprintf(stderr, "UDP peer unavailable; retrying discovery\n");
                (void)send(socket_fd, "PCAM-GCM-RX", 11, MSG_DONTWAIT);
                active = 0;
                received = 0U;
                memset(seen, 0, PACKET_COUNT);
                continue;
            }
            perror("recv");
            return -1;
        }
        if (length != UDP_RECORD_BYTES)
            continue;

        uint16_t index = load_be16(packet + 12U);
        uint32_t packet_session = load_be32(packet + 4U);
        uint32_t packet_frame = load_be32(packet + 8U);
        if (index >= PACKET_COUNT)
            continue;

        if (!active) {
            if (index != 0U)
                continue;
            session = packet_session;
            frame = packet_frame;
            active = 1;
        } else if (index == 0U &&
                   (packet_session != session || packet_frame != frame)) {
            session = packet_session;
            frame = packet_frame;
            received = 0U;
            memset(seen, 0, PACKET_COUNT);
        }

        if (!packet_header_valid(packet, session, frame, index) || seen[index])
            continue;
        memcpy(network_buffer + (size_t)index * UDP_RECORD_BYTES,
               packet, UDP_RECORD_BYTES);
        seen[index] = 1U;
        ++received;
    }

    *session_out = session;
    *frame_out = frame;
    __sync_synchronize();
    return stop_requested ? -1 : 0;
}

static int replay_feed_packet(struct receiver_context *context,
                              const uint8_t *packet, uint32_t normal_session,
                              uint32_t normal_frame);

static int
receive_frame_direct(struct receiver_context *context,
                     uint8_t *network_buffer,
                     uint32_t *session_out, uint32_t *frame_out)
{
    uint32_t session = 0U, frame = 0U;
    unsigned int expected = 0U;
    int active = 0;

    while (!stop_requested && expected != PACKET_COUNT) {
        struct iovec vector;
        struct msghdr message;
        uint8_t *chunk;
        size_t bytes;
        unsigned int records;

        if (context->pending_length) {
            chunk = context->pending;
            bytes = context->pending_length;
            context->pending_length = 0U;
        } else {
            ssize_t received;
            size_t capacity;

            chunk = network_buffer + (size_t)expected * UDP_RECORD_BYTES;
            capacity = NETWORK_BUFFER_STRIDE -
                       (size_t)expected * UDP_RECORD_BYTES;

            if (capacity > RECEIVE_BUFFER_BYTES)
                capacity = RECEIVE_BUFFER_BYTES;
            memset(&message, 0, sizeof(message));
            vector.iov_base = chunk;
            vector.iov_len = capacity;
            message.msg_iov = &vector;
            message.msg_iovlen = 1U;
            do {
                received = recvmsg(context->socket_fd, &message,
                                   MSG_TRUNC);
            } while (received < 0 && errno == EINTR && !stop_requested);
            if (received < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK ||
                    errno == ECONNREFUSED) {
                    fprintf(stderr,
                            "UDP peer unavailable; retrying discovery\n");
                    (void)send(context->socket_fd, "PCAM-GCM-RX", 11,
                               MSG_DONTWAIT);
                    active = 0;
                    expected = 0U;
                    context->pending_length = 0U;
                    continue;
                }
                perror("recv");
                return -1;
            }
            bytes = (size_t)received;
            if (bytes > capacity) {
                active = 0;
                expected = 0U;
                context->pending_length = 0U;
                continue;
            }
        }

        if (!bytes || bytes % UDP_RECORD_BYTES) {
            active = 0;
            expected = 0U;
            context->pending_length = 0U;
            continue;
        }
        records = (unsigned int)(bytes / UDP_RECORD_BYTES);

        for (unsigned int record = 0U; record < records; ++record) {
            uint8_t *packet = chunk + (size_t)record * UDP_RECORD_BYTES;
            uint32_t packet_session = load_be32(packet + 4U);
            uint32_t packet_frame = load_be32(packet + 8U);
            uint16_t index = load_be16(packet + 12U);

            if (index >= PACKET_COUNT ||
                !packet_header_valid(packet, packet_session,
                                     packet_frame, index))
                continue;
            if (!active) {
                if (context->have_last_normal &&
                    packet_session == context->last_normal_session &&
                    (int32_t)(packet_frame -
                              context->last_normal_frame) < 0) {
                    if (replay_feed_packet(context, packet,
                                           context->last_normal_session,
                                           context->last_normal_frame) < 0)
                        return -1;
                    continue;
                }
                if (index != 0U)
                    continue;
                session = packet_session;
                frame = packet_frame;
                expected = 0U;
                active = 1;
            }
            if (packet_session == session && packet_frame == frame) {
                if (index != expected)
                    continue;
                memmove(network_buffer +
                        (size_t)expected * UDP_RECORD_BYTES,
                        packet, UDP_RECORD_BYTES);
                ++expected;
                if (expected == PACKET_COUNT) {
                    unsigned int remaining = records - record - 1U;
                    if (remaining) {
                        context->pending_length =
                            (size_t)remaining * UDP_RECORD_BYTES;
                        memcpy(context->pending,
                               packet + UDP_RECORD_BYTES,
                               context->pending_length);
                    }
                    context->last_normal_session = session;
                    context->last_normal_frame = frame;
                    context->have_last_normal = 1;
                    break;
                }
                continue;
            }
            if (packet_session == session &&
                (int32_t)(packet_frame - frame) < 0) {
                if (replay_feed_packet(context, packet,
                                       session, frame) < 0)
                    return -1;
                continue;
            }
            if (index == 0U &&
                (packet_session != session ||
                 (int32_t)(packet_frame - frame) > 0)) {
                session = packet_session;
                frame = packet_frame;
                expected = 0U;
                memmove(network_buffer, packet, UDP_RECORD_BYTES);
                expected = 1U;
                active = 1;
            }
        }
    }

    *session_out = session;
    *frame_out = frame;
    __sync_synchronize();
    return stop_requested ? -1 : 0;
}

static int frame_queue_init(struct frame_queue *queue,
                            uint8_t *receive_buffers[FRAME_QUEUE_COUNT],
                            uint8_t *network_buffers[FRAME_QUEUE_COUNT],
                            const int network_fds[FRAME_QUEUE_COUNT],
                            const uint32_t network_handles[FRAME_QUEUE_COUNT],
                            const uint32_t network_addresses[FRAME_QUEUE_COUNT])
{
    memset(queue, 0, sizeof(*queue));
    if (pthread_mutex_init(&queue->mutex, NULL) != 0 ||
        pthread_cond_init(&queue->condition, NULL) != 0)
        return -1;

    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        queue->slots[i].data = receive_buffers[i];
        queue->slots[i].dma_data = network_buffers[i];
        queue->slots[i].physical = network_addresses[i];
        queue->slots[i].dmabuf_fd = network_fds[i];
        queue->slots[i].dma_handle = network_handles[i];
    }
    return 0;
}

static void frame_queue_destroy(struct frame_queue *queue)
{
    pthread_cond_destroy(&queue->condition);
    pthread_mutex_destroy(&queue->mutex);
}

static void frame_queue_publish_received(struct frame_queue *queue,
                                         struct frame_slot *slot,
                                         uint32_t session, uint32_t frame)
{
    pthread_mutex_lock(&queue->mutex);
    slot->session = session;
    slot->frame = frame;
    slot->serial = ++queue->serial;
    slot->state = SLOT_RECEIVED;
    pthread_cond_broadcast(&queue->condition);
    pthread_mutex_unlock(&queue->mutex);
}

static struct frame_slot *frame_queue_take_state(struct frame_queue *queue,
                                                 enum frame_slot_state wanted,
                                                 enum frame_slot_state claimed)
{
    struct frame_slot *selected;

    pthread_mutex_lock(&queue->mutex);
    for (;;) {
        selected = NULL;
        for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
            if (queue->slots[i].state == wanted &&
                (!selected || queue->slots[i].serial < selected->serial))
                selected = &queue->slots[i];
        }
        if (selected || stop_requested || queue->receiver_failed)
            break;
        pthread_cond_wait(&queue->condition, &queue->mutex);
    }
    if (selected)
        selected->state = claimed;
    pthread_mutex_unlock(&queue->mutex);
    return selected;
}

static struct frame_slot *frame_queue_take_normal_free(
    struct frame_queue *queue)
{
    struct frame_slot *selected;

    pthread_mutex_lock(&queue->mutex);
    for (;;) {
        selected = NULL;
        for (unsigned int i = 0; i < NORMAL_FRAME_SLOTS; ++i) {
            if (queue->slots[i].state == SLOT_FREE) {
                selected = &queue->slots[i];
                break;
            }
        }
        if (selected || stop_requested || queue->receiver_failed)
            break;
        pthread_cond_wait(&queue->condition, &queue->mutex);
    }
    if (selected)
        selected->state = SLOT_FILLING;
    pthread_mutex_unlock(&queue->mutex);
    return selected;
}

static void frame_queue_publish_ready(struct frame_queue *queue,
                                      struct frame_slot *slot)
{
    pthread_mutex_lock(&queue->mutex);
    slot->serial = ++queue->serial;
    slot->state = SLOT_READY;
    pthread_cond_broadcast(&queue->condition);
    pthread_mutex_unlock(&queue->mutex);
}

static void frame_queue_release(struct frame_queue *queue,
                                struct frame_slot *slot)
{
    pthread_mutex_lock(&queue->mutex);
    slot->received_packets = 0U;
    slot->sync_active = 0;
    slot->state = SLOT_FREE;
    pthread_cond_broadcast(&queue->condition);
    pthread_mutex_unlock(&queue->mutex);
}

static int receiver_sync_slot(struct receiver_context *context,
                              struct frame_slot *slot, uint64_t flags)
{
    const double started = monotonic_seconds();
    int result = sync_dmabuf(slot->dmabuf_fd, flags);

    context->sync_seconds += monotonic_seconds() - started;
    return result;
}

static int replay_feed_packet(struct receiver_context *context,
                              const uint8_t *packet, uint32_t normal_session,
                              uint32_t normal_frame)
{
    struct frame_slot *slot =
        &context->queue->slots[REPLAY_FRAME_SLOT];
    uint32_t session = load_be32(packet + 4U);
    uint32_t frame = load_be32(packet + 8U);
    uint16_t index = load_be16(packet + 12U);
    double now = monotonic_seconds();
    int completed = 0;

    if (session != normal_session ||
        (int32_t)(frame - normal_frame) >= 0 ||
        index >= PACKET_COUNT || !slot->data)
        return 0;

    pthread_mutex_lock(&context->queue->mutex);
    if (slot->state != SLOT_FREE && slot->state != SLOT_FILLING) {
        pthread_mutex_unlock(&context->queue->mutex);
        return 0;
    }
    if (slot->state == SLOT_FILLING &&
        now - slot->last_packet_time >=
            FRAME_ASSEMBLY_TIMEOUT_MS / 1000.0) {
        ++context->queue->stale_drops;
        slot->state = SLOT_FREE;
        slot->received_packets = 0U;
    }
    if (slot->state == SLOT_FREE) {
        if (index != 0U) {
            pthread_mutex_unlock(&context->queue->mutex);
            return 0;
        }
        slot->session = session;
        slot->frame = frame;
        slot->received_packets = 0U;
        slot->first_packet_time = now;
        memset(slot->seen, 0, sizeof(slot->seen));
        slot->state = SLOT_FILLING;
    } else if (slot->session != session || slot->frame != frame) {
        if (index != 0U) {
            pthread_mutex_unlock(&context->queue->mutex);
            return 0;
        }
        ++context->queue->stale_drops;
        slot->session = session;
        slot->frame = frame;
        slot->received_packets = 0U;
        slot->first_packet_time = now;
        memset(slot->seen, 0, sizeof(slot->seen));
    }
    if (!slot->seen[index]) {
        memcpy(slot->data + (size_t)index * UDP_RECORD_BYTES,
               packet, UDP_RECORD_BYTES);
        slot->seen[index] = 1U;
        ++slot->received_packets;
    }
    slot->last_packet_time = now;
    completed = slot->received_packets == PACKET_COUNT;
    pthread_mutex_unlock(&context->queue->mutex);

    if (!completed)
        return 0;
    if (receiver_sync_slot(context, slot,
                           DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) < 0) {
        perror("DMA-BUF begin replay frame copy");
        frame_queue_release(context->queue, slot);
        return -1;
    }
    memcpy(slot->dma_data, slot->data, NETWORK_FRAME_BYTES);
    if (receiver_sync_slot(context, slot,
                           DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) < 0) {
        perror("DMA-BUF end replay frame copy");
        frame_queue_release(context->queue, slot);
        return -1;
    }
    frame_queue_publish_ready(context->queue, slot);
    return 0;
}

static void frame_queue_fail_receiver(struct frame_queue *queue)
{
    pthread_mutex_lock(&queue->mutex);
    queue->receiver_failed = 1;
    pthread_cond_broadcast(&queue->condition);
    pthread_mutex_unlock(&queue->mutex);
}

static int frame_queue_discard_filling(struct receiver_context *context,
                                       struct frame_slot *slot,
                                       int count_stale)
{
    int needs_sync;

    pthread_mutex_lock(&context->queue->mutex);
    if (slot->state != SLOT_FILLING) {
        pthread_mutex_unlock(&context->queue->mutex);
        return 0;
    }
    needs_sync = slot->sync_active;
    slot->sync_active = 0;
    slot->received_packets = 0U;
    slot->state = SLOT_FREE;
    if (count_stale)
        ++context->queue->stale_drops;
    pthread_cond_broadcast(&context->queue->condition);
    pthread_mutex_unlock(&context->queue->mutex);

    if (needs_sync &&
        receiver_sync_slot(context, slot,
                           DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) < 0) {
        perror("DMA-BUF end discarded assembly");
        return -1;
    }
    return 0;
}

static int frame_queue_reset_assemblies(struct receiver_context *context)
{
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        if (frame_queue_discard_filling(context,
                                        &context->queue->slots[i], 0) < 0)
            return -1;
    }
    return 0;
}

static int frame_queue_expire_assemblies(struct receiver_context *context,
                                         double now)
{
    const double timeout = FRAME_ASSEMBLY_TIMEOUT_MS / 1000.0;

    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        struct frame_slot *slot = &context->queue->slots[i];
        int expired;

        pthread_mutex_lock(&context->queue->mutex);
        expired = slot->state == SLOT_FILLING &&
                  now - slot->last_packet_time >= timeout;
        pthread_mutex_unlock(&context->queue->mutex);
        if (expired && frame_queue_discard_filling(context, slot, 1) < 0)
            return -1;
    }
    return 0;
}

static int frame_queue_claim_assembly(struct receiver_context *context,
                                      uint32_t session, uint32_t frame,
                                      double now, struct frame_slot **slot_out)
{
    struct frame_slot *selected = NULL;
    struct frame_slot *oldest = NULL;
    int old_sync_active = 0;

    *slot_out = NULL;
    pthread_mutex_lock(&context->queue->mutex);
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        struct frame_slot *slot = &context->queue->slots[i];

        if (slot->state == SLOT_FILLING && slot->session == session &&
            slot->frame == frame) {
            *slot_out = slot;
            pthread_mutex_unlock(&context->queue->mutex);
            return 1;
        }
        if (slot->state == SLOT_FREE && !selected)
            selected = slot;
        if (slot->state == SLOT_FILLING &&
            (!oldest || slot->last_packet_time < oldest->last_packet_time))
            oldest = slot;
    }
    if (!selected) {
        selected = oldest;
        if (selected)
            ++context->queue->overruns;
    }
    if (!selected) {
        ++context->queue->overruns;
        pthread_mutex_unlock(&context->queue->mutex);
        return 0;
    }

    old_sync_active = selected->sync_active;
    selected->session = session;
    selected->frame = frame;
    selected->received_packets = 0U;
    selected->first_packet_time = now;
    selected->last_packet_time = now;
    selected->sync_active = 0;
    memset(selected->seen, 0, sizeof(selected->seen));
    selected->state = SLOT_FILLING;
    pthread_mutex_unlock(&context->queue->mutex);

    if (old_sync_active &&
        receiver_sync_slot(context, selected,
                           DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) < 0) {
        perror("DMA-BUF end evicted assembly");
        frame_queue_release(context->queue, selected);
        return -1;
    }
    if (context->cma_direct) {
        if (receiver_sync_slot(context, selected,
                               DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) < 0) {
            perror("DMA-BUF begin keyed assembly");
            frame_queue_release(context->queue, selected);
            return -1;
        }
        selected->sync_active = 1;
    }
    *slot_out = selected;
    return 1;
}

static int receive_interleaved_packet(struct receiver_context *context,
                                      const uint8_t *packet, size_t length)
;

static int receive_interleaved_chunk(struct receiver_context *context,
                                     const uint8_t *data, size_t length)
{
    double now = monotonic_seconds();
    size_t record = 0U;
    size_t records;

    if (!length || length > RECEIVE_BUFFER_BYTES ||
        length % UDP_RECORD_BYTES)
        return 0;
    if (frame_queue_expire_assemblies(context, now) < 0)
        return -1;
    records = length / UDP_RECORD_BYTES;

    while (record < records) {
        const uint8_t *packet = data + record * UDP_RECORD_BYTES;
        struct frame_slot *slot;
        uint32_t session = load_be32(packet + 4U);
        uint32_t frame = load_be32(packet + 8U);
        uint16_t first = load_be16(packet + 12U);
        size_t run = 1U;
        int claim_result;
        int all_unseen = 1;

        if (first >= PACKET_COUNT ||
            !packet_header_valid(packet, session, frame, first)) {
            ++record;
            continue;
        }
        if (!context->have_assembly_session) {
            context->assembly_session = session;
            context->have_assembly_session = 1;
        } else if (first == 0U && session != context->assembly_session) {
            if (frame_queue_reset_assemblies(context) < 0)
                return -1;
            context->assembly_session = session;
        }

        while (record + run < records && first + run < PACKET_COUNT) {
            const uint8_t *next = data +
                                  (record + run) * UDP_RECORD_BYTES;
            if (!packet_header_valid(next, session, frame,
                                     (uint16_t)(first + run)))
                break;
            ++run;
        }

        claim_result = frame_queue_claim_assembly(context, session, frame,
                                                   now, &slot);
        if (claim_result < 0)
            return -1;
        if (!claim_result) {
            record += run;
            continue;
        }
        for (size_t i = 0; i < run; ++i) {
            if (slot->seen[first + i]) {
                all_unseen = 0;
                break;
            }
        }
        if (all_unseen) {
            memcpy(slot->data + (size_t)first * UDP_RECORD_BYTES,
                   packet, run * UDP_RECORD_BYTES);
            memset(slot->seen + first, 1, run);
            slot->received_packets += (unsigned int)run;
        } else {
            for (size_t i = 0; i < run; ++i) {
                uint16_t index = (uint16_t)(first + i);
                if (slot->seen[index])
                    continue;
                memcpy(slot->data + (size_t)index * UDP_RECORD_BYTES,
                       packet + i * UDP_RECORD_BYTES, UDP_RECORD_BYTES);
                slot->seen[index] = 1U;
                ++slot->received_packets;
            }
        }
        slot->last_packet_time = now;
        record += run;
        if (slot->received_packets != PACKET_COUNT)
            continue;

        __sync_synchronize();
        if (context->cma_direct) {
            if (receiver_sync_slot(context, slot,
                                   DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) < 0) {
                perror("DMA-BUF end completed assembly");
                frame_queue_release(context->queue, slot);
                return -1;
            }
            slot->sync_active = 0;
            ++context->sync_frames;
            frame_queue_publish_ready(context->queue, slot);
        } else {
            frame_queue_publish_received(context->queue, slot, session, frame);
        }
    }
    return 0;
}

static int receive_interleaved_packet(struct receiver_context *context,
                                      const uint8_t *packet, size_t length)
{
    return receive_interleaved_chunk(context, packet, length);
}

static void make_self_test_packet(uint8_t *packet, uint32_t session,
                                  uint32_t frame, uint16_t index)
{
    uint32_t value32;
    uint16_t value16;
    uint16_t flags = (uint16_t)(PROTOCOL_VERSION << 12);

    memset(packet, (int)(frame & 0xffU), UDP_RECORD_BYTES);
    value32 = htonl(PACKET_MAGIC);
    memcpy(packet, &value32, sizeof(value32));
    value32 = htonl(session);
    memcpy(packet + 4U, &value32, sizeof(value32));
    value32 = htonl(frame);
    memcpy(packet + 8U, &value32, sizeof(value32));
    value16 = htons(index);
    memcpy(packet + 12U, &value16, sizeof(value16));
    if (index == 0U)
        flags |= 1U << 1;
    if (index + 1U == PACKET_COUNT)
        flags |= 1U << 2;
    flags |= 1U;
    value16 = htons(flags);
    memcpy(packet + 14U, &value16, sizeof(value16));
}

static int multiframe_reassembly_self_test(void)
{
    struct frame_queue queue;
    struct receiver_context context = {0};
    uint8_t *buffers[FRAME_QUEUE_COUNT] = {0};
    uint8_t *dma_buffers[FRAME_QUEUE_COUNT] = {0};
    int fds[FRAME_QUEUE_COUNT] = {-1, -1, -1, -1};
    uint32_t handles[FRAME_QUEUE_COUNT] = {0};
    uint32_t addresses[FRAME_QUEUE_COUNT] = {0};
    uint8_t first[UDP_RECORD_BYTES], second[UDP_RECORD_BYTES];
    struct frame_slot *frame_100 = NULL, *frame_50 = NULL;
    int result = -1;

    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        buffers[i] = calloc(1, NETWORK_BUFFER_STRIDE);
        dma_buffers[i] = buffers[i];
        if (!buffers[i])
            goto cleanup_buffers;
    }
    if (frame_queue_init(&queue, buffers, dma_buffers, fds, handles,
                         addresses) < 0)
        goto cleanup_buffers;
    context.queue = &queue;
    receiver_init(&context.packets);

    for (uint16_t index = 0U; index < PACKET_COUNT; ++index) {
        make_self_test_packet(first, 7U, 100U, index);
        make_self_test_packet(second, 7U, 50U, index);
        if (receive_interleaved_packet(&context, first, sizeof(first)) < 0 ||
            (index == 0U &&
             receive_interleaved_packet(&context, first, sizeof(first)) < 0) ||
            receive_interleaved_packet(&context, second, sizeof(second)) < 0)
            goto cleanup_queue;
    }
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        struct frame_slot *slot = &queue.slots[i];

        if (slot->state == SLOT_RECEIVED && slot->session == 7U &&
            slot->frame == 100U)
            frame_100 = slot;
        if (slot->state == SLOT_RECEIVED && slot->session == 7U &&
            slot->frame == 50U)
            frame_50 = slot;
    }
    if (!frame_100 || !frame_50 ||
        frame_100->received_packets != PACKET_COUNT ||
        frame_50->received_packets != PACKET_COUNT ||
        load_be32(frame_100->data + 8U) != 100U ||
        load_be32(frame_50->data +
                  (PACKET_COUNT - 1U) * UDP_RECORD_BYTES + 8U) != 50U)
        goto cleanup_queue;

    make_self_test_packet(first, 7U, 101U, 0U);
    if (receive_interleaved_packet(&context, first, sizeof(first)) < 0)
        goto cleanup_queue;
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        if (queue.slots[i].state == SLOT_FILLING &&
            queue.slots[i].frame == 101U)
            queue.slots[i].last_packet_time -=
                FRAME_ASSEMBLY_TIMEOUT_MS / 1000.0 + 0.001;
    }
    if (frame_queue_expire_assemblies(&context, monotonic_seconds()) < 0 ||
        queue.stale_drops != 1U)
        goto cleanup_queue;

    make_self_test_packet(first, 7U, 102U, 0U);
    make_self_test_packet(second, 8U, 1U, 0U);
    if (receive_interleaved_packet(&context, first, sizeof(first)) < 0 ||
        receive_interleaved_packet(&context, second, sizeof(second)) < 0)
        goto cleanup_queue;
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        if (queue.slots[i].state == SLOT_FILLING &&
            queue.slots[i].session == 7U)
            goto cleanup_queue;
    }

    fprintf(stderr,
            "PASS: keyed interleaved frames, duplicate suppression, timeout, session reset\n");
    result = 0;

cleanup_queue:
    frame_queue_destroy(&queue);
cleanup_buffers:
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i)
        free(buffers[i]);
    if (result != 0)
        fprintf(stderr, "FAIL: keyed multi-frame reassembly\n");
    return result;
}

static void *receive_worker(void *opaque)
{
    struct receiver_context *context = opaque;
    cpu_set_t affinity;

    CPU_ZERO(&affinity);
    /*
     * GEM RX IRQ/NAPI/softirq traffic is fixed on CPU0 on this Zynq image.
     * Keeping userspace receive there saturated CPU0 and overflowed the UDP
     * socket.  CPU1 has enough headroom because AES DMA waits in hardware.
     */
    CPU_SET(1, &affinity);
    (void)pthread_setaffinity_np(pthread_self(), sizeof(affinity), &affinity);
    while (!stop_requested) {
        struct frame_slot *slot =
            frame_queue_take_normal_free(context->queue);
        uint8_t *destination;
        uint32_t session, frame;

        if (!slot)
            break;
        destination = context->cma_direct ? slot->dma_data : slot->data;
        if (context->cma_direct) {
            if (receiver_sync_slot(context, slot,
                                   DMA_BUF_SYNC_START |
                                   DMA_BUF_SYNC_WRITE) < 0) {
                perror("DMA-BUF begin ordered frame");
                frame_queue_release(context->queue, slot);
                break;
            }
            slot->sync_active = 1;
        }
        if (receive_frame_direct(context, destination,
                                 &session, &frame) < 0) {
            if (slot->sync_active)
                (void)receiver_sync_slot(context, slot,
                                         DMA_BUF_SYNC_END |
                                         DMA_BUF_SYNC_WRITE);
            frame_queue_release(context->queue, slot);
            break;
        }
        slot->session = session;
        slot->frame = frame;
        if (context->cma_direct) {
            if (receiver_sync_slot(context, slot,
                                   DMA_BUF_SYNC_END |
                                   DMA_BUF_SYNC_WRITE) < 0) {
                perror("DMA-BUF end ordered frame");
                frame_queue_release(context->queue, slot);
                break;
            }
            slot->sync_active = 0;
            ++context->sync_frames;
            frame_queue_publish_ready(context->queue, slot);
        } else {
            frame_queue_publish_received(context->queue, slot,
                                         session, frame);
        }
    }

    frame_queue_fail_receiver(context->queue);
    return NULL;
}

static void *copy_worker(void *opaque)
{
    struct copy_context *context = opaque;
    cpu_set_t affinity;

    CPU_ZERO(&affinity);
    CPU_SET(1, &affinity);
    (void)pthread_setaffinity_np(pthread_self(), sizeof(affinity), &affinity);
    while (!stop_requested) {
        struct frame_slot *slot = frame_queue_take_state(
            context->queue, SLOT_RECEIVED, SLOT_COPYING);
        double started;

        if (!slot)
            break;
        started = monotonic_seconds();
        if (sync_dmabuf(slot->dmabuf_fd,
                        DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) < 0) {
            perror("DMA-BUF begin staged frame copy");
            context->failed = 1;
            frame_queue_release(context->queue, slot);
            break;
        }
        memcpy(slot->dma_data, slot->data, NETWORK_FRAME_BYTES);
        if (sync_dmabuf(slot->dmabuf_fd,
                        DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) < 0) {
            perror("DMA-BUF end staged frame copy");
            context->failed = 1;
            frame_queue_release(context->queue, slot);
            break;
        }
        context->seconds += monotonic_seconds() - started;
        ++context->frames;
        frame_queue_publish_ready(context->queue, slot);
    }

    pthread_mutex_lock(&context->queue->mutex);
    if (context->failed)
        context->queue->receiver_failed = 1;
    pthread_cond_broadcast(&context->queue->condition);
    pthread_mutex_unlock(&context->queue->mutex);
    return NULL;
}

int main(int argc, char **argv)
{
    const char *tx_address = argc > 1 ? argv[1] : "auto";
    int port = argc > 2 ? atoi(argv[2]) : 5602;
    const char *telemetry_uart = getenv("PC_TELEMETRY_UART");
    const char *telemetry_baud_text = getenv("PC_TELEMETRY_UART_BAUD");
    unsigned long telemetry_baud = telemetry_baud_text ?
        strtoul(telemetry_baud_text, NULL, 0) :
        TELEMETRY_UART_BAUD_DEFAULT;
    int mem_fd = -1, bridge_fd = -1, heap_fd = -1;
    int socket_fd = -1, result = EXIT_FAILURE;
    int network_dmabuf[FRAME_QUEUE_COUNT] = {-1, -1, -1, -1};
    int video_dmabuf[VIDEO_BUFFER_COUNT] = {-1, -1, -1};
    uint32_t network_handles[FRAME_QUEUE_COUNT] = {0};
    uint32_t network_addresses[FRAME_QUEUE_COUNT] = {0};
    uint32_t video_handles[VIDEO_BUFFER_COUNT] = {0};
    uint32_t video_addresses[VIDEO_BUFFER_COUNT] = {0};
    volatile uint32_t *vdma = MAP_FAILED;
    volatile uint32_t *gpio = MAP_FAILED;
    volatile uint32_t *error_gpio = MAP_FAILED;
    volatile uint32_t *session_regs = MAP_FAILED;
    uint8_t *network_buffers[FRAME_QUEUE_COUNT] = {
        MAP_FAILED, MAP_FAILED, MAP_FAILED, MAP_FAILED
    };
    uint8_t *receive_buffers[FRAME_QUEUE_COUNT] = {NULL, NULL, NULL, NULL};
    uint8_t *video_buffers[VIDEO_BUFFER_COUNT] = {
        MAP_FAILED, MAP_FAILED, MAP_FAILED
    };
    struct frame_queue queue;
    struct receiver_context receiver = {0};
    struct copy_context copier = {0};
    pthread_t receiver_thread;
    pthread_t copy_thread;
    pthread_t telemetry_thread;
    struct display_stats stats = {0};
    struct freshness_state freshness = {0};
    struct telemetry_context telemetry;
    uint32_t previous_status = 0U;
    unsigned int display_index = 0U;
    int display_started = 0;
    int queue_initialized = 0;
    int receiver_started = 0;
    int copier_started = 0;
    int telemetry_initialized = 0;
    int telemetry_started = 0;
    int debug_packet_dumped = 0;
    int debug_frame_dumped = 0;
    int dump_frame_requested = getenv("PCAM_DUMP_FRAME") &&
                               strcmp(getenv("PCAM_DUMP_FRAME"), "1") == 0;
    long dump_frame_target = -1;
    int cma_direct = !getenv("PCAM_RX_CMA_DIRECT") ||
                     strcmp(getenv("PCAM_RX_CMA_DIRECT"), "0") != 0;
    uint64_t processed_frames = 0U;
    uint64_t authentication_failures = 0U;
    uint64_t replay_rejections = 0U;
    uint64_t status_failures = 0U;
    double dma_seconds = 0.0;
    double status_seconds = 0.0;
    char learned_tx_address[INET_ADDRSTRLEN] = "";

    if (argc > 1 && strcmp(argv[1], "--self-test") == 0)
        return freshness_self_test() == 0 &&
               multiframe_reassembly_self_test() == 0 ?
               EXIT_SUCCESS : EXIT_FAILURE;

    if (getenv("PCAM_DUMP_FRAME_ID")) {
        dump_frame_target = strtol(getenv("PCAM_DUMP_FRAME_ID"), NULL, 0);
        dump_frame_requested = dump_frame_target >= 0;
    }

    if (port <= 0 || port > 65535 || telemetry_baud > UINT32_MAX ||
        telemetry_uart_speed((unsigned int)telemetry_baud) == (speed_t)0) {
        fprintf(stderr, "invalid video UDP port or telemetry UART baud\n");
        return EXIT_FAILURE;
    }
    if (telemetry_uart == NULL || *telemetry_uart == '\0')
        telemetry_uart = TELEMETRY_UART_DEFAULT;
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    tune_available_rx_rings();
    {
        cpu_set_t affinity;
        CPU_ZERO(&affinity);
        CPU_SET(1, &affinity);
        if (pthread_setaffinity_np(pthread_self(), sizeof(affinity),
                                   &affinity) != 0)
            fprintf(stderr, "warning: could not pin RX processing to CPU1\n");
    }

    mem_fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (mem_fd < 0) {
        perror("open /dev/mem");
        goto cleanup;
    }
    vdma = map_physical(mem_fd, VDMA_BASE, REGISTER_SPAN);
    gpio = map_physical(mem_fd, GPIO_BASE, REGISTER_SPAN);
    error_gpio = map_physical(mem_fd, ERROR_GPIO_BASE, REGISTER_SPAN);
    session_regs = map_physical(mem_fd, SESSION_BASE, REGISTER_SPAN);
    if (vdma == MAP_FAILED || gpio == MAP_FAILED || error_gpio == MAP_FAILED ||
        session_regs == MAP_FAILED)
        goto cleanup;
    if (reg_read(session_regs, SESSION_REG_ID) != SESSION_REG_MAGIC) {
        fprintf(stderr, "AES session register ID is invalid\n");
        goto cleanup;
    }
    /* Clear a reservation left by a userspace process that was killed after
     * DMA completion.  This does not clear or replace the active key. */
    if (release_session_frame(session_regs) < 0) {
        perror("release stale AES frame reservation");
        goto cleanup;
    }

    bridge_fd = open("/dev/pcam_aes_bridge", O_RDWR | O_CLOEXEC);
    if (bridge_fd < 0) {
        perror("open /dev/pcam_aes_bridge");
        goto cleanup;
    }
    {
        struct pcam_aes_info info = {0};
        if (ioctl(bridge_fd, PCAM_AES_IOC_GET_INFO, &info) < 0 ||
            info.abi_version != PCAM_AES_ABI_VERSION) {
            fprintf(stderr, "incompatible PCAM AES bridge ABI\n");
            goto cleanup;
        }
    }
    heap_fd = open_cma_heap();
    if (heap_fd < 0)
        goto cleanup;

    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        if (!cma_direct || i == REPLAY_FRAME_SLOT) {
            receive_buffers[i] = malloc(NETWORK_BUFFER_STRIDE);
            if (!receive_buffers[i])
                goto cleanup;
        }
        network_dmabuf[i] = allocate_dmabuf(heap_fd, NETWORK_BUFFER_STRIDE);
        if (network_dmabuf[i] < 0)
            goto cleanup;
        network_buffers[i] = mmap(NULL, NETWORK_BUFFER_STRIDE,
                                  PROT_READ | PROT_WRITE, MAP_SHARED,
                                  network_dmabuf[i], 0);
        if (network_buffers[i] == MAP_FAILED ||
            import_dmabuf(bridge_fd, network_dmabuf[i],
                          PCAM_AES_BUFFER_INPUT, &network_handles[i],
                          &network_addresses[i]) < 0)
            goto cleanup;
        fprintf(stderr, "RX input%u handle=%u dma=0x%08x\n", i,
                network_handles[i], network_addresses[i]);
    }
    for (unsigned int i = 0; i < VIDEO_BUFFER_COUNT; ++i) {
        video_dmabuf[i] = allocate_dmabuf(heap_fd, VIDEO_BUFFER_STRIDE);
        if (video_dmabuf[i] < 0)
            goto cleanup;
        video_buffers[i] = mmap(NULL, VIDEO_BUFFER_STRIDE,
                                PROT_READ | PROT_WRITE, MAP_SHARED,
                                video_dmabuf[i], 0);
        if (video_buffers[i] == MAP_FAILED ||
            import_dmabuf(bridge_fd, video_dmabuf[i],
                          PCAM_AES_BUFFER_OUTPUT, &video_handles[i],
                          &video_addresses[i]) < 0)
            goto cleanup;
        fprintf(stderr, "RX video%u handle=%u dma=0x%08x\n", i,
                video_handles[i], video_addresses[i]);
        if (sync_dmabuf(video_dmabuf[i],
                        DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) < 0)
            goto cleanup;
        memset(video_buffers[i], 0x10, VIDEO_BUFFER_STRIDE);
        if (sync_dmabuf(video_dmabuf[i],
                        DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) < 0)
            goto cleanup;
    }
    fprintf(stderr, "CMA DMA-BUF network/video buffers enabled\n");

    if (frame_queue_init(&queue, receive_buffers, network_buffers,
                         network_dmabuf,
                         network_handles, network_addresses) < 0) {
        fprintf(stderr, "frame queue allocation failed\n");
        goto cleanup;
    }
    queue_initialized = 1;
    if (cma_direct) {
        for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i)
            queue.slots[i].data = network_buffers[i];
    }
    reg_write(gpio, GPIO_TRI, 0xffffffffU);
    reg_write(error_gpio, GPIO_TRI, 0xffffffffU);
    reg_write(error_gpio, GPIO2_TRI, 0x00000000U);
    reg_write(error_gpio, GPIO2_DATA, 0x00000000U);
    previous_status = reg_read(gpio, GPIO_DATA);

    socket_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (socket_fd < 0) {
        perror("socket");
        goto cleanup;
    }
    {
        /* Linux reports twice the requested SO_RCVBUF.  Do not reserve most
         * of this 512-MiB board for one socket: under load that caused UDP
         * MemErrors and made complete frames scarce.  Both values remain
         * runtime-selectable for measured A/B tests. */
        const char *buffer_mb_text = getenv("PCAM_RX_RCVBUF_MB");
        const char *gro_text = getenv("PCAM_RX_GRO");
        unsigned long buffer_mb = buffer_mb_text ?
                                  strtoul(buffer_mb_text, NULL, 0) : 8U;
        int size;
        int udp_gro = !gro_text || strcmp(gro_text, "0") != 0;
        struct timeval timeout = {2, 0};
        struct sockaddr_in local = {0};
        struct sockaddr_in peer = {0};

        if (buffer_mb < 1U)
            buffer_mb = 1U;
        if (buffer_mb > 32U)
            buffer_mb = 32U;
        size = (int)(buffer_mb * 1024U * 1024U);
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
        if (udp_gro)
            setsockopt(socket_fd, IPPROTO_UDP, UDP_GRO,
                       &udp_gro, sizeof(udp_gro));
        fprintf(stderr, "UDP GRO %s; recvmmsg batch=%u x %u bytes\n",
                udp_gro ? "enabled" : "disabled",
                RECEIVE_BATCH, RECEIVE_BUFFER_BYTES);
        fprintf(stderr,
                "UDP receive path ordered-GRO normal plus isolated replay assembly\n");
        fprintf(stderr, "UDP receive memory %s\n",
                cma_direct ? "cacheable CMA DMA-BUF (zero-copy)" :
                             "cacheable staging plus CMA copy");
        {
            socklen_t size_length = sizeof(size);
            if (getsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF,
                           &size, &size_length) == 0)
                fprintf(stderr, "UDP receive buffer %d bytes\n", size);
        }
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, sizeof(timeout));
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_ANY);
        local.sin_port = htons((uint16_t)port);
        if (bind(socket_fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
            perror("bind RX UDP port");
            goto cleanup;
        }
        if (strcmp(tx_address, "auto") == 0) {
            fprintf(stderr,
                    "RX discovering TX from live PCAM packets on all active IPv4 interfaces\n");
            if (discover_video_sender(socket_fd, (unsigned int)port,
                                      &peer) < 0) {
                perror("discover TX video sender");
                goto cleanup;
            }
        } else {
            peer.sin_family = AF_INET;
            peer.sin_port = htons((uint16_t)port);
            if (inet_pton(AF_INET, tx_address, &peer.sin_addr) != 1 ||
                connect(socket_fd, (struct sockaddr *)&peer, sizeof(peer)) < 0) {
                fprintf(stderr, "invalid/unreachable TX address %s:%d\n",
                        tx_address, port);
                goto cleanup;
            }
            (void)persist_runtime_tx_peer(&peer);
            if (send(socket_fd, "PCAM-GCM-RX", 11, 0) != 11) {
                perror("send hello");
                goto cleanup;
            }
        }
        if (inet_ntop(AF_INET, &peer.sin_addr, learned_tx_address,
                      sizeof(learned_tx_address)) == NULL)
            snprintf(learned_tx_address, sizeof(learned_tx_address),
                     "unknown");
    }

    fprintf(stderr, "AES_GCM_RX learned TX %s:%d\n",
            learned_tx_address, port);

    if (telemetry_init(&telemetry, &queue, telemetry_uart,
                       (unsigned int)telemetry_baud, error_gpio) < 0)
        goto cleanup;
    telemetry_initialized = 1;
    if (telemetry.enabled &&
        pthread_create(&telemetry_thread, NULL, telemetry_worker,
                       &telemetry) != 0) {
        fprintf(stderr, "RX telemetry worker creation failed\n");
        goto cleanup;
    }
    telemetry_started = telemetry.enabled;

    receiver.socket_fd = socket_fd;
    receiver.cma_direct = cma_direct;
    receiver.queue = &queue;
    receiver_init(&receiver.packets);
    copier.queue = &queue;
    if (!cma_direct) {
        if (pthread_create(&copy_thread, NULL, copy_worker, &copier) != 0) {
            fprintf(stderr, "CMA copy worker creation failed\n");
            goto cleanup;
        }
        copier_started = 1;
    }
    if (pthread_create(&receiver_thread, NULL, receive_worker, &receiver) != 0) {
        fprintf(stderr, "UDP receiver thread creation failed\n");
        goto cleanup;
    }
    receiver_started = 1;

    while (!stop_requested) {
        struct frame_slot *slot;
        uint32_t session, frame, status;
        double phase_started;
        unsigned int write_index = display_started ?
                                   ((display_index + 1U) % VIDEO_BUFFER_COUNT) :
                                   0U;

        slot = frame_queue_take_state(&queue, SLOT_READY, SLOT_PROCESSING);
        if (!slot)
            break;
        session = slot->session;
        frame = slot->frame;

        /* BTN3 key removal and release rekey are frame-boundary operations.
         * Every mode carries a session ID, including plaintext bypass.  Never
         * feed a queued old-session frame to a newly keyed engine; VDMA keeps
         * displaying the last completed frame until matching traffic arrives. */
        {
            uint32_t session_status_before =
                reg_read(session_regs, SESSION_REG_STATUS);
            uint32_t active_session =
                reg_read(session_regs, SESSION_REG_ACTIVE_ID);
            uint32_t session_status_after =
                reg_read(session_regs, SESSION_REG_STATUS);
            int session_ready =
                session_status_before == session_status_after &&
                (session_status_after & SESSION_STATUS_READY_MASK) ==
                    SESSION_STATUS_READY_MASK &&
                (session_status_after & SESSION_STATUS_TRANSITION_MASK) == 0U;

            if (!session_ready || active_session == 0U ||
                active_session != session) {
                if ((frame % 30U) == 0U)
                    fprintf(stderr,
                            "SESSION_DROP frame=%u packet_session=0x%08x active=0x%08x status=0x%08x\n",
                            frame, session, active_session,
                            session_status_after);
                frame_queue_release(&queue, slot);
                continue;
            }
        }
        if (dump_frame_requested && !debug_frame_dumped &&
            (dump_frame_target < 0 || frame == (uint32_t)dump_frame_target)) {
            int dump_fd = open("/tmp/rx_encrypted_frame.bin",
                               O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                               0600);
            if (dump_fd >= 0) {
                if (write(dump_fd, slot->data, NETWORK_FRAME_BYTES) ==
                    (ssize_t)NETWORK_FRAME_BYTES)
                    debug_frame_dumped = 1;
                else
                    perror("write encrypted frame dump");
                close(dump_fd);
            } else {
                perror("open encrypted frame dump");
            }
        }
        if (!debug_packet_dumped &&
            (load_be16(slot->data + 14U) & 1U)) {
            int dump_fd = open("/tmp/rx_encrypted_packet0.bin",
                               O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                               0600);
            if (dump_fd >= 0) {
                if (write(dump_fd, slot->data, UDP_RECORD_BYTES) ==
                    (ssize_t)UDP_RECORD_BYTES)
                    debug_packet_dumped = 1;
                close(dump_fd);
            }
        }
        phase_started = monotonic_seconds();
        if (acquire_session_frame(session_regs) < 0) {
            if (errno != EAGAIN)
                perror("acquire AES frame reservation");
            frame_queue_release(&queue, slot);
            continue;
        }
        /* ACQUIRE can race with a just-completed rekey.  While the lock is
         * held the active ID is stable, so this final equality check is the
         * authoritative decision for the queued frame. */
        if (reg_read(session_regs, SESSION_REG_ACTIVE_ID) != session) {
            if (release_session_frame(session_regs) < 0)
                perror("release AES frame reservation");
            frame_queue_release(&queue, slot);
            continue;
        }
        telemetry_attempt(&telemetry, session);
        {
            int dma_result = run_frame_dma(bridge_fd, slot->dma_handle,
                                           video_handles[write_index]);
            int release_result = release_session_frame(session_regs);

            if (release_result < 0)
                perror("release AES frame reservation");
            if (dma_result < 0) {
                perror("DMAengine AES frame");
                frame_queue_release(&queue, slot);
                break;
            }
        }
        dma_seconds += monotonic_seconds() - phase_started;

        phase_started = monotonic_seconds();
        if (wait_frame_status(gpio, previous_status, &status) < 0) {
            fprintf(stderr, "RX status timeout frame=%u previous=0x%08x\n",
                    frame, previous_status);
            ++status_failures;
            ++processed_frames;
            telemetry_status_failure(&telemetry);
            frame_queue_release(&queue, slot);
            continue;
        }
        status_seconds += monotonic_seconds() - phase_started;
        previous_status = status;
        if (STATUS_FRAME16(status) != (uint16_t)frame) {
            fprintf(stderr,
                    "RX status mismatch frame=%u status=0x%08x\n",
                    frame, status);
            ++status_failures;
            ++processed_frames;
            telemetry_status_failure(&telemetry);
            frame_queue_release(&queue, slot);
            continue;
        }

        if (STATUS_FAILED(status)) {
            ++authentication_failures;
            ++processed_frames;
            telemetry_auth_reject(&telemetry);
            security_event_send(&telemetry, "gcm_auth_fail", session, frame,
                                0U, 0);
            if ((frame % 30U) == 0U)
                fprintf(stderr,
                        "DROP frame=%u session=0x%08x authentication/format failed\n",
                        frame, session);
            if (getenv("PCAM_DUMP_FAILED") &&
                access("/tmp/rx_failed_frame.bin", F_OK) != 0) {
                int dump_fd = open("/tmp/rx_failed_frame.bin",
                                   O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                                   0600);
                if (dump_fd >= 0) {
                    ssize_t written = write(dump_fd, slot->data,
                                            NETWORK_FRAME_BYTES);
                    if (written != (ssize_t)NETWORK_FRAME_BYTES)
                        perror("write failed encrypted frame");
                    close(dump_fd);
                }
            }
            frame_queue_release(&queue, slot);
            if ((processed_frames % 30U) == 0U)
                fprintf(stderr,
                        "PIPE processed=%llu auth_fail=%llu replay_reject=%llu status_fail=%llu queue_overrun=%llu stale=%llu avg_ms prepare=%.2f dma_aes=%.2f submit=%.2f wait=%.2f status=%.2f\n",
                        (unsigned long long)processed_frames,
                        (unsigned long long)authentication_failures,
                        (unsigned long long)replay_rejections,
                        (unsigned long long)status_failures,
                        (unsigned long long)queue.overruns,
                        (unsigned long long)queue.stale_drops,
                        cma_direct ?
                            (receiver.sync_frames ?
                             receiver.sync_seconds * 1000.0 /
                             receiver.sync_frames : 0.0) :
                            (copier.frames ? copier.seconds * 1000.0 /
                                             copier.frames : 0.0),
                        dma_seconds * 1000.0 / processed_frames,
                        dma_call_count ? dma_submit_seconds * 1000.0 /
                                         dma_call_count : 0.0,
                        dma_call_count ? dma_wait_seconds * 1000.0 /
                                         dma_call_count : 0.0,
                        status_seconds * 1000.0 / processed_frames);
            continue;
        }

        {
            uint32_t network_loss = 0U;

            if (!freshness_accept(&freshness, session, frame,
                                  &network_loss)) {
                ++replay_rejections;
                ++processed_frames;
                telemetry_replay_reject(&telemetry);
                security_event_send(&telemetry, "replay_reject", session,
                                    frame, freshness.last_frame, 1);
                frame_queue_release(&queue, slot);
                fprintf(stderr,
                        "REPLAY_DROP frame=%u session=0x%08x last=%u\n",
                        frame, session, freshness.last_frame);
                continue;
            }
            telemetry_accept(&telemetry, session, network_loss);
        }

        ++processed_frames;
        frame_queue_release(&queue, slot);

        update_stats(&stats, session, frame);

        if (!display_started) {
            if (start_vdma(vdma, video_addresses) < 0)
                break;
            display_started = 1;
        }
        reg_write(vdma, VDMA_PARK_PTR, write_index);
        display_index = write_index;
        if ((processed_frames % 30U) == 0U)
            fprintf(stderr,
                    "PIPE processed=%llu auth_fail=%llu replay_reject=%llu status_fail=%llu queue_overrun=%llu stale=%llu avg_ms prepare=%.2f dma_aes=%.2f submit=%.2f wait=%.2f status=%.2f\n",
                    (unsigned long long)processed_frames,
                    (unsigned long long)authentication_failures,
                    (unsigned long long)replay_rejections,
                    (unsigned long long)status_failures,
                    (unsigned long long)queue.overruns,
                    (unsigned long long)queue.stale_drops,
                    cma_direct ?
                        (receiver.sync_frames ?
                         receiver.sync_seconds * 1000.0 /
                         receiver.sync_frames : 0.0) :
                        (copier.frames ? copier.seconds * 1000.0 /
                                         copier.frames : 0.0),
                    dma_seconds * 1000.0 / processed_frames,
                    dma_call_count ? dma_submit_seconds * 1000.0 /
                                     dma_call_count : 0.0,
                    dma_call_count ? dma_wait_seconds * 1000.0 /
                                     dma_call_count : 0.0,
                    status_seconds * 1000.0 / processed_frames);
    }

    result = EXIT_SUCCESS;

cleanup:
    stop_requested = 1;
    if (socket_fd >= 0)
        shutdown(socket_fd, SHUT_RDWR);
    if (queue_initialized) {
        pthread_mutex_lock(&queue.mutex);
        pthread_cond_broadcast(&queue.condition);
        pthread_mutex_unlock(&queue.mutex);
    }
    if (receiver_started)
        pthread_join(receiver_thread, NULL);
    if (copier_started)
        pthread_join(copy_thread, NULL);
    if (telemetry_started)
        pthread_join(telemetry_thread, NULL);
    if (socket_fd >= 0)
        close(socket_fd);
    for (unsigned int i = 0; i < FRAME_QUEUE_COUNT; ++i) {
        free(receive_buffers[i]);
        if (network_buffers[i] != MAP_FAILED)
            munmap(network_buffers[i], NETWORK_BUFFER_STRIDE);
        if (network_dmabuf[i] >= 0)
            close(network_dmabuf[i]);
    }
    for (unsigned int i = 0; i < VIDEO_BUFFER_COUNT; ++i) {
        if (video_buffers[i] != MAP_FAILED)
            munmap(video_buffers[i], VIDEO_BUFFER_STRIDE);
        if (video_dmabuf[i] >= 0)
            close(video_dmabuf[i]);
    }
    if (vdma != MAP_FAILED)
        munmap((void *)vdma, REGISTER_SPAN);
    if (gpio != MAP_FAILED)
        munmap((void *)gpio, REGISTER_SPAN);
    if (error_gpio != MAP_FAILED)
        munmap((void *)error_gpio, REGISTER_SPAN);
    if (session_regs != MAP_FAILED)
        munmap((void *)session_regs, REGISTER_SPAN);
    if (mem_fd >= 0)
        close(mem_fd);
    if (heap_fd >= 0)
        close(heap_fd);
    if (bridge_fd >= 0)
        close(bridge_fd);
    if (queue_initialized)
        frame_queue_destroy(&queue);
    if (telemetry_initialized)
        telemetry_destroy(&telemetry);
    return result;
}
