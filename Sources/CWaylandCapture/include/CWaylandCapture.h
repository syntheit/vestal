// One screenshot of one Wayland output, for the Linux UI's self-blurred
// backdrop (theme.backdrop "self"). Blocking, on its own Wayland connection
// (WAYLAND_DISPLAY), so it runs on any thread and never touches GTK's.
// ext-image-copy-capture-v1 when the compositor has it, else
// wlr-screencopy-unstable-v1; into shared memory, without the cursor.
#ifndef VESTAL_WAYLAND_CAPTURE_H
#define VESTAL_WAYLAND_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

enum vestal_capture_status {
    VESTAL_CAPTURE_OK = 0,
    /// No Wayland display to connect to.
    VESTAL_CAPTURE_NO_DISPLAY = 1,
    /// Neither capture protocol (or no wl_shm): the compositor can't.
    VESTAL_CAPTURE_UNSUPPORTED = 2,
    /// No output by that name (or several outputs and no name given).
    VESTAL_CAPTURE_NO_OUTPUT = 3,
    /// The deadline passed.
    VESTAL_CAPTURE_TIMEOUT = 4,
    /// The compositor refused or the connection broke.
    VESTAL_CAPTURE_FAILED = 5,
};

typedef struct vestal_capture {
    /// The pixels, mapped shared memory of `size` bytes: `height` rows of
    /// `stride` bytes, in `format` (a wl_shm format code). Valid until
    /// `vestal_capture_release`.
    void *data;
    size_t size;
    int32_t width, height, stride;
    uint32_t format;
    /// The rows are bottom to top (wlr-screencopy's y_invert flag).
    int32_t y_invert;
    /// ext-image-copy-capture's buffer transform (a wl_output_transform).
    uint32_t transform;
    /// "ext-image-copy-capture-v1" or "wlr-screencopy-unstable-v1".
    const char *protocol;
    /// The output captured.
    char output[64];
    /// Why it failed, for the log.
    char error[256];
} vestal_capture;

/// Captures the output named `output` (a connector name such as "DP-1", as
/// wl_output's `name` event gives it), or the only output when `output` is
/// NULL, within `timeout_ms`. Returns a `vestal_capture_status`; on
/// VESTAL_CAPTURE_OK, `out` holds the pixels and must be released.
int vestal_capture_output(const char *output, int timeout_ms, vestal_capture *out);

/// Unmaps the pixels. Safe on a failed or already released capture.
void vestal_capture_release(vestal_capture *capture);

#endif
