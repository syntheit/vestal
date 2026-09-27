// See include/CWaylandCapture.h. The protocol glue next to this file is
// wayland-scanner's output for protocols/*.xml (see protocols/README).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "CWaylandCapture.h"

#include <errno.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"

#define MAX_OUTPUTS 16

// The 32-bit formats the Linux UI uploads (Aurora.swift's SelfBlur), in the
// order preferred when the compositor offers several.
static const uint32_t accepted_formats[] = {
    WL_SHM_FORMAT_XRGB8888, WL_SHM_FORMAT_ARGB8888, WL_SHM_FORMAT_XBGR8888, WL_SHM_FORMAT_ABGR8888,
    WL_SHM_FORMAT_XRGB2101010, WL_SHM_FORMAT_ARGB2101010, WL_SHM_FORMAT_XBGR2101010, WL_SHM_FORMAT_ABGR2101010,
};
#define N_ACCEPTED (sizeof(accepted_formats) / sizeof(accepted_formats[0]))

static int accepted_rank(uint32_t format) {
    for (size_t i = 0; i < N_ACCEPTED; i++) {
        if (accepted_formats[i] == format) return (int)i;
    }
    return -1;
}

struct output {
    struct wl_output *wl;
    char name[64];
};

struct state {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_shm *shm;
    struct zwlr_screencopy_manager_v1 *wlr;
    uint32_t wlr_version;
    struct ext_image_copy_capture_manager_v1 *ext_copy;
    struct ext_output_image_capture_source_manager_v1 *ext_source;
    struct output outputs[MAX_OUTPUTS];
    int n_outputs;

    // The frame being captured.
    int32_t width, height, stride;
    uint32_t format;
    int best_rank;          // ext: the best offered format so far (-1: none)
    int info_done;          // the buffer's constraints are known
    int ready, failed, stopped;
    int frame_done;         // ready or failed
    int32_t y_invert;
    uint32_t transform;
    uint32_t fail_reason;
};

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void set_error(vestal_capture *out, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(out->error, sizeof(out->error), format, args);
    va_end(args);
}

/// Dispatches events until `*flag` is set, the connection fails, or the
/// deadline passes. Never blocks past the deadline (unlike
/// wl_display_roundtrip). Returns 0, VESTAL_CAPTURE_TIMEOUT or _FAILED.
static int pump(struct state *s, const int *flag, int64_t deadline) {
    while (!*flag) {
        while (wl_display_prepare_read(s->display) != 0) {
            if (wl_display_dispatch_pending(s->display) < 0) return VESTAL_CAPTURE_FAILED;
            if (*flag) return 0;
        }
        if (wl_display_flush(s->display) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(s->display);
            return VESTAL_CAPTURE_FAILED;
        }
        int64_t remaining = deadline - now_ms();
        if (remaining <= 0) {
            wl_display_cancel_read(s->display);
            return VESTAL_CAPTURE_TIMEOUT;
        }
        struct pollfd fd = { .fd = wl_display_get_fd(s->display), .events = POLLIN };
        int polled = poll(&fd, 1, (int)remaining);
        if (polled <= 0) {
            wl_display_cancel_read(s->display);
            if (polled < 0 && errno == EINTR) continue;
            if (polled == 0) return VESTAL_CAPTURE_TIMEOUT;
            return VESTAL_CAPTURE_FAILED;
        }
        if (wl_display_read_events(s->display) < 0) return VESTAL_CAPTURE_FAILED;
        if (wl_display_dispatch_pending(s->display) < 0) return VESTAL_CAPTURE_FAILED;
    }
    return 0;
}

static void sync_done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    *(int *)data = 1;
    wl_callback_destroy(callback);
}

static const struct wl_callback_listener sync_listener = { .done = sync_done };

/// A round trip within the deadline.
static int roundtrip(struct state *s, int64_t deadline) {
    int done = 0;
    struct wl_callback *callback = wl_display_sync(s->display);
    if (!callback) return VESTAL_CAPTURE_FAILED;
    wl_callback_add_listener(callback, &sync_listener, &done);
    int status = pump(s, &done, deadline);
    // Not answered: the callback dies with the connection; its listener
    // data (`done`, on this stack) is never touched again, since nothing
    // dispatches after this returns an error.
    return status;
}

// MARK: Registry and outputs

static void output_geometry(void *data, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                            int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    (void)data; (void)o; (void)flags; (void)w; (void)h; (void)refresh;
}
static void output_done(void *data, struct wl_output *o) { (void)data; (void)o; }
static void output_scale(void *data, struct wl_output *o, int32_t factor) { (void)data; (void)o; (void)factor; }
static void output_name(void *data, struct wl_output *o, const char *name) {
    (void)o;
    struct output *output = data;
    snprintf(output->name, sizeof(output->name), "%s", name);
}
static void output_description(void *data, struct wl_output *o, const char *description) {
    (void)data; (void)o; (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static uint32_t min_u32(uint32_t a, uint32_t b) { return a < b ? a : b; }

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
                            uint32_t version) {
    struct state *s = data;
    if (strcmp(interface, wl_shm_interface.name) == 0 && !s->shm) {
        s->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_output_interface.name) == 0 && s->n_outputs < MAX_OUTPUTS) {
        // Version 4 for the `name` event; older outputs stay unnamed.
        struct output *output = &s->outputs[s->n_outputs++];
        output->wl = wl_registry_bind(registry, name, &wl_output_interface, min_u32(version, 4));
        wl_output_add_listener(output->wl, &output_listener, output);
    } else if (strcmp(interface, zwlr_screencopy_manager_v1_interface.name) == 0 && !s->wlr) {
        s->wlr_version = min_u32(version, 3);
        s->wlr = wl_registry_bind(registry, name, &zwlr_screencopy_manager_v1_interface, s->wlr_version);
    } else if (strcmp(interface, ext_image_copy_capture_manager_v1_interface.name) == 0 && !s->ext_copy) {
        s->ext_copy = wl_registry_bind(registry, name, &ext_image_copy_capture_manager_v1_interface, 1);
    } else if (strcmp(interface, ext_output_image_capture_source_manager_v1_interface.name) == 0 && !s->ext_source) {
        s->ext_source = wl_registry_bind(registry, name, &ext_output_image_capture_source_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

// MARK: Shared memory

/// A memfd of `size` bytes, mapped, and a wl_buffer on it. The fd is closed
/// here; the mapping outlives the buffer, the pool and the connection.
static struct wl_buffer *create_buffer(struct state *s, vestal_capture *out) {
    size_t size = (size_t)s->stride * (size_t)s->height;
    int fd = memfd_create("vestal-capture", MFD_CLOEXEC);
    if (fd < 0) {
        set_error(out, "memfd_create: %s", strerror(errno));
        return NULL;
    }
    if (ftruncate(fd, (off_t)size) < 0) {
        set_error(out, "ftruncate: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        set_error(out, "mmap: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(s->shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, s->width, s->height, s->stride, s->format);
    wl_shm_pool_destroy(pool);
    close(fd);
    out->data = data;
    out->size = size;
    return buffer;
}

// MARK: ext-image-copy-capture-v1

static void session_buffer_size(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t w,
                                uint32_t h) {
    (void)session;
    struct state *s = data;
    s->width = (int32_t)w;
    s->height = (int32_t)h;
}
static void session_shm_format(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format) {
    (void)session;
    struct state *s = data;
    int rank = accepted_rank(format);
    if (rank >= 0 && (s->best_rank < 0 || rank < s->best_rank)) {
        s->best_rank = rank;
        s->format = format;
    }
}
static void session_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *session,
                                  struct wl_array *device) {
    (void)data; (void)session; (void)device;
}
static void session_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format,
                                  struct wl_array *modifiers) {
    (void)data; (void)session; (void)format; (void)modifiers;
}
static void session_done(void *data, struct ext_image_copy_capture_session_v1 *session) {
    (void)session;
    ((struct state *)data)->info_done = 1;
}
static void session_stopped(void *data, struct ext_image_copy_capture_session_v1 *session) {
    (void)session;
    struct state *s = data;
    s->stopped = 1;
    s->failed = 1;
    s->info_done = 1;
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    .buffer_size = session_buffer_size,
    .shm_format = session_shm_format,
    .dmabuf_device = session_dmabuf_device,
    .dmabuf_format = session_dmabuf_format,
    .done = session_done,
    .stopped = session_stopped,
};

static void ext_frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t transform) {
    (void)frame;
    ((struct state *)data)->transform = transform;
}
static void ext_frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *frame, int32_t x, int32_t y,
                             int32_t w, int32_t h) {
    (void)data; (void)frame; (void)x; (void)y; (void)w; (void)h;
}
static void ext_frame_presentation_time(void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t hi,
                                        uint32_t lo, uint32_t nsec) {
    (void)data; (void)frame; (void)hi; (void)lo; (void)nsec;
}
static void ext_frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *frame) {
    (void)frame;
    struct state *s = data;
    s->ready = 1;
    s->frame_done = 1;
}
static void ext_frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t reason) {
    (void)frame;
    struct state *s = data;
    s->failed = 1;
    s->fail_reason = reason;
    s->frame_done = 1;
}

static const struct ext_image_copy_capture_frame_v1_listener ext_frame_listener = {
    .transform = ext_frame_transform,
    .damage = ext_frame_damage,
    .presentation_time = ext_frame_presentation_time,
    .ready = ext_frame_ready,
    .failed = ext_frame_failed,
};

static int capture_ext(struct state *s, struct wl_output *output, int64_t deadline, vestal_capture *out) {
    struct ext_image_capture_source_v1 *source =
        ext_output_image_capture_source_manager_v1_create_source(s->ext_source, output);
    struct ext_image_copy_capture_session_v1 *session =
        ext_image_copy_capture_manager_v1_create_session(s->ext_copy, source, 0);
    ext_image_copy_capture_session_v1_add_listener(session, &session_listener, s);
    struct ext_image_copy_capture_frame_v1 *frame = NULL;
    struct wl_buffer *buffer = NULL;
    int status = pump(s, &s->info_done, deadline);
    if (status == 0 && s->stopped) {
        set_error(out, "the compositor stopped the capture session");
        status = VESTAL_CAPTURE_FAILED;
    } else if (status == 0 && (s->best_rank < 0 || s->width <= 0 || s->height <= 0)) {
        set_error(out, "no usable shared-memory format (%dx%d)", s->width, s->height);
        status = VESTAL_CAPTURE_FAILED;
    }
    if (status == 0) {
        s->stride = s->width * 4;
        buffer = create_buffer(s, out);
        if (!buffer) status = VESTAL_CAPTURE_FAILED;
    }
    if (status == 0) {
        frame = ext_image_copy_capture_session_v1_create_frame(session);
        ext_image_copy_capture_frame_v1_add_listener(frame, &ext_frame_listener, s);
        ext_image_copy_capture_frame_v1_attach_buffer(frame, buffer);
        ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, s->width, s->height);
        ext_image_copy_capture_frame_v1_capture(frame);
        status = pump(s, &s->frame_done, deadline);
        if (status == 0 && s->failed) {
            set_error(out, "the compositor failed the frame (reason %u)", s->fail_reason);
            status = VESTAL_CAPTURE_FAILED;
        }
    }
    if (frame) ext_image_copy_capture_frame_v1_destroy(frame);
    if (buffer) wl_buffer_destroy(buffer);
    ext_image_copy_capture_session_v1_destroy(session);
    ext_image_capture_source_v1_destroy(source);
    out->protocol = "ext-image-copy-capture-v1";
    return status;
}

// MARK: wlr-screencopy-unstable-v1

static void wlr_frame_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format, uint32_t w,
                             uint32_t h, uint32_t stride) {
    (void)frame;
    struct state *s = data;
    s->format = format;
    s->width = (int32_t)w;
    s->height = (int32_t)h;
    s->stride = (int32_t)stride;
    s->best_rank = accepted_rank(format);
    // Before version 3 there is no buffer_done: this is all there is.
    if (s->wlr_version < 3) s->info_done = 1;
}
static void wlr_frame_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t flags) {
    (void)frame;
    ((struct state *)data)->y_invert = (flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
}
static void wlr_frame_ready(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t hi, uint32_t lo,
                            uint32_t nsec) {
    (void)frame; (void)hi; (void)lo; (void)nsec;
    struct state *s = data;
    s->ready = 1;
    s->frame_done = 1;
}
static void wlr_frame_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
    (void)frame;
    struct state *s = data;
    s->failed = 1;
    s->info_done = 1;
    s->frame_done = 1;
}
static void wlr_frame_damage(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t x, uint32_t y, uint32_t w,
                             uint32_t h) {
    (void)data; (void)frame; (void)x; (void)y; (void)w; (void)h;
}
static void wlr_frame_linux_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format, uint32_t w,
                                   uint32_t h) {
    (void)data; (void)frame; (void)format; (void)w; (void)h;
}
static void wlr_frame_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
    (void)frame;
    ((struct state *)data)->info_done = 1;
}

static const struct zwlr_screencopy_frame_v1_listener wlr_frame_listener = {
    .buffer = wlr_frame_buffer,
    .flags = wlr_frame_flags,
    .ready = wlr_frame_ready,
    .failed = wlr_frame_failed,
    .damage = wlr_frame_damage,
    .linux_dmabuf = wlr_frame_linux_dmabuf,
    .buffer_done = wlr_frame_buffer_done,
};

static int capture_wlr(struct state *s, struct wl_output *output, int64_t deadline, vestal_capture *out) {
    struct zwlr_screencopy_frame_v1 *frame = zwlr_screencopy_manager_v1_capture_output(s->wlr, 0, output);
    zwlr_screencopy_frame_v1_add_listener(frame, &wlr_frame_listener, s);
    struct wl_buffer *buffer = NULL;
    int status = pump(s, &s->info_done, deadline);
    if (status == 0 && s->failed) {
        set_error(out, "the compositor failed the frame");
        status = VESTAL_CAPTURE_FAILED;
    } else if (status == 0 && (s->best_rank < 0 || s->width <= 0 || s->height <= 0 || s->stride < s->width * 4)) {
        set_error(out, "unusable buffer: format 0x%08x, %dx%d, stride %d", s->format, s->width, s->height, s->stride);
        status = VESTAL_CAPTURE_FAILED;
    }
    if (status == 0) {
        buffer = create_buffer(s, out);
        if (!buffer) status = VESTAL_CAPTURE_FAILED;
    }
    if (status == 0) {
        zwlr_screencopy_frame_v1_copy(frame, buffer);
        status = pump(s, &s->frame_done, deadline);
        if (status == 0 && s->failed) {
            set_error(out, "the compositor failed the copy");
            status = VESTAL_CAPTURE_FAILED;
        }
    }
    if (buffer) wl_buffer_destroy(buffer);
    zwlr_screencopy_frame_v1_destroy(frame);
    out->protocol = "wlr-screencopy-unstable-v1";
    return status;
}

// MARK: Entry points

int vestal_capture_output(const char *output_name, int timeout_ms, vestal_capture *out) {
    memset(out, 0, sizeof(*out));
    int64_t deadline = now_ms() + (timeout_ms > 0 ? timeout_ms : 1);
    struct state s;
    memset(&s, 0, sizeof(s));
    s.best_rank = -1;
    s.display = wl_display_connect(NULL);
    if (!s.display) {
        set_error(out, "cannot connect to the Wayland display");
        return VESTAL_CAPTURE_NO_DISPLAY;
    }
    s.registry = wl_display_get_registry(s.display);
    wl_registry_add_listener(s.registry, &registry_listener, &s);
    // Globals, then the outputs' names (sent after each bind).
    int status = roundtrip(&s, deadline);
    if (status == 0) status = roundtrip(&s, deadline);
    if (status == VESTAL_CAPTURE_TIMEOUT) set_error(out, "the compositor did not answer in time");
    else if (status != 0) set_error(out, "the Wayland connection failed");

    int use_ext = s.ext_copy && s.ext_source;
    if (status == 0 && (!s.shm || (!use_ext && !s.wlr))) {
        set_error(out, "the compositor has neither ext-image-copy-capture-v1 nor wlr-screencopy-unstable-v1");
        status = VESTAL_CAPTURE_UNSUPPORTED;
    }
    struct output *target = NULL;
    if (status == 0) {
        for (int i = 0; i < s.n_outputs; i++) {
            if (output_name ? strcmp(s.outputs[i].name, output_name) == 0 : s.n_outputs == 1) {
                target = &s.outputs[i];
                break;
            }
        }
        if (!target) {
            if (output_name) set_error(out, "no output named %s", output_name);
            else set_error(out, "%d outputs and no name to choose one", s.n_outputs);
            status = VESTAL_CAPTURE_NO_OUTPUT;
        } else {
            snprintf(out->output, sizeof(out->output), "%s", target->name);
        }
    }
    if (status == 0) {
        status = use_ext ? capture_ext(&s, target->wl, deadline, out) : capture_wlr(&s, target->wl, deadline, out);
        if (status == VESTAL_CAPTURE_TIMEOUT) set_error(out, "no frame within %d ms", timeout_ms);
        else if (status == VESTAL_CAPTURE_FAILED && out->error[0] == 0) set_error(out, "the Wayland connection failed");
    }
    if (status == 0) {
        out->width = s.width;
        out->height = s.height;
        out->stride = s.stride;
        out->format = s.format;
        out->y_invert = s.y_invert;
        out->transform = s.transform;
    }

    // Client-side cleanup; the compositor drops the rest on disconnect.
    for (int i = 0; i < s.n_outputs; i++) wl_proxy_destroy((struct wl_proxy *)s.outputs[i].wl);
    if (s.shm) wl_proxy_destroy((struct wl_proxy *)s.shm);
    if (s.wlr) zwlr_screencopy_manager_v1_destroy(s.wlr);
    if (s.ext_copy) ext_image_copy_capture_manager_v1_destroy(s.ext_copy);
    if (s.ext_source) ext_output_image_capture_source_manager_v1_destroy(s.ext_source);
    wl_registry_destroy(s.registry);
    wl_display_flush(s.display);
    wl_display_disconnect(s.display);

    if (status != 0) vestal_capture_release(out);
    return status;
}

void vestal_capture_release(vestal_capture *capture) {
    if (capture->data) munmap(capture->data, capture->size);
    capture->data = NULL;
    capture->size = 0;
}
