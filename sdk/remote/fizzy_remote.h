/* fizzy_remote.h — find, quietly start and connect to the installed fizzy.
 *
 * The C ABI of sdk/remote/capi.zig. A host application's adapter (Blender, Unreal, ...) opens a
 * handle, then sends and receives whole frames of the remote-view protocol (sdk/remote/README.md).
 * Calls on one handle are not thread safe; two handles are independent. Every function returns a
 * fizzy_remote_status, 0 on success.
 *
 *   fizzy_remote_options o = {0};
 *   o.size = sizeof o;
 *   o.host_name = "blender";
 *   fizzy_remote *r;
 *   int st = fizzy_remote_open(&o, &r);
 *   if (st != FIZZY_REMOTE_OK) show(fizzy_remote_status_string(st));
 */
#ifndef FIZZY_REMOTE_H
#define FIZZY_REMOTE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fizzy_remote fizzy_remote;

typedef enum fizzy_remote_status {
    FIZZY_REMOTE_OK = 0,
    /* No fizzy where one would be installed. */
    FIZZY_REMOTE_NOT_INSTALLED = 1,
    /* Nothing listens and FIZZY_REMOTE_NO_START was set. */
    FIZZY_REMOTE_NOT_RUNNING = 2,
    /* This process's sandbox hides or forbids fizzy. A private second fizzy is never started. */
    FIZZY_REMOTE_SANDBOXED = 3,
    /* Fizzy has no remote view or speaks only older protocols: the person updates fizzy. */
    FIZZY_REMOTE_FIZZY_TOO_OLD = 4,
    /* Fizzy speaks only newer protocols: the person updates this add-on. */
    FIZZY_REMOTE_CLIENT_TOO_OLD = 5,
    /* Fizzy did not answer by timeout_ms. */
    FIZZY_REMOTE_TIMED_OUT = 6,
    /* The fizzy that was started exited with a failure before it listened. */
    FIZZY_REMOTE_START_FAILED = 7,
    FIZZY_REMOTE_PROTOCOL = 8,
    /* The connection ended (fizzy quit, or a bye): call fizzy_remote_reconnect. */
    FIZZY_REMOTE_CLOSED = 9,
    FIZZY_REMOTE_OUT_OF_MEMORY = 10,
    /* fizzy_remote_recv: the frame is kept, *len is the size it needs. */
    FIZZY_REMOTE_BUFFER_TOO_SMALL = 11,
    FIZZY_REMOTE_INVALID_ARGUMENT = 12
} fizzy_remote_status;

/* fizzy_remote_options.flags */
enum {
    /* Connect to a running fizzy; never start one. */
    FIZZY_REMOTE_NO_START = 1
};

/* Every string is NUL-terminated or NULL (the default, or the environment's). */
typedef struct fizzy_remote_options {
    uint32_t size;        /* sizeof this struct */
    uint32_t timeout_ms;  /* for open and reconnect, a start included; 0 is 15000 */
    uint32_t flags;
    const char *host_name;     /* what the host calls itself in its hello */
    const char *host_version;
    /* The application to find, for an app built on fizzy: executable and pack id, macOS bundle
     * name, bundle id. Fizzy's own when NULL. */
    const char *app_name;
    const char *app_display_name;
    const char *app_bundle_id;
    /* Override FIZZY_EXE and FIZZY_PROFILE, and name the socket directly (for a host that cannot
     * run fizzy to ask for it). */
    const char *exe;
    const char *profile;
    const char *socket_path;
} fizzy_remote_options;

/* Find the installed fizzy, start it quietly (never taking focus) if nothing listens, connect
 * and exchange hellos. On success *out is a handle for fizzy_remote_close. */
int fizzy_remote_open(const fizzy_remote_options *options, fizzy_remote **out);

/* Connect again after FIZZY_REMOTE_CLOSED, starting fizzy if it quit. Views are gone with the old
 * stream: create them again. */
int fizzy_remote_reconnect(fizzy_remote *r);

/* Send one whole frame, as encoded for the wire. */
int fizzy_remote_send(fizzy_remote *r, const uint8_t *frame, size_t len);

/* The next frame from fizzy into buf, waiting up to timeout_ms (negative: forever). *len is its
 * length, 0 with FIZZY_REMOTE_OK if the wait passed. A frame larger than cap is kept:
 * FIZZY_REMOTE_BUFFER_TOO_SMALL with *len the size needed; call again with room. */
int fizzy_remote_recv(fizzy_remote *r, uint8_t *buf, size_t cap, size_t *len, int32_t timeout_ms);

/* The control socket in use, valid until the next call on r; NULL before a connect. */
const char *fizzy_remote_socket_path(const fizzy_remote *r);

/* A short English reason for a status, for a log. Never NULL. */
const char *fizzy_remote_status_string(int status);

/* The newest protocol version this library speaks. */
uint32_t fizzy_remote_protocol_version(void);

/* End the connection and free the handle. Fizzy keeps running. */
void fizzy_remote_close(fizzy_remote *r);

#ifdef __cplusplus
}
#endif

#endif
