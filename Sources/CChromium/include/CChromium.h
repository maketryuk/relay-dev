#ifndef RELAY_CCHROMIUM_H
#define RELAY_CCHROMIUM_H

// The whole of what Relay asks of Chromium, in terms Swift can import.
//
// The CEF headers stay behind this one: they describe several hundred
// callbacks, and Swift would import every one of them to use a dozen. What
// crosses here is plain C — strings, numbers, an opaque handle and a table of
// function pointers — so the Swift side never has to know how CEF counts
// references or spells a string.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One page, embedded in a view Relay owns.
typedef struct relay_chromium_browser relay_chromium_browser;

/// What a page reports back. Every callback arrives on the main thread, and
/// none arrives after `closed`.
typedef struct relay_chromium_callbacks {
    void *context;
    void (*created)(void *context);
    void (*address_changed)(void *context, const char *url);
    void (*title_changed)(void *context, const char *title);
    void (*loading_changed)(void *context, int is_loading, int can_go_back, int can_go_forward);
    void (*load_failed)(void *context, int code, const char *text, const char *url);
    /// A reply or an event from the page's DevTools agent, as the JSON text
    /// the protocol sends. Not NUL-terminated.
    void (*devtools_message)(void *context, const char *json, size_t length);
    /// A link that asked for a new tab or window. The page is left where it
    /// is; opening the address is up to the receiver.
    void (*opens_in_new_tab)(void *context, const char *url);
    void (*focused)(void *context);
    void (*renderer_gone)(void *context, int status);
    void (*closed)(void *context);
} relay_chromium_callbacks;

typedef struct relay_chromium_settings {
    const char *main_bundle_path;
    const char *framework_path;
    const char *helper_path;
    const char *cache_path;
    const char *log_path;
    /// Chromium's own spelling: `en-US`, `ru`.
    const char *locale;
    /// Drawn before a page has painted anything, as 0xAARRGGBB.
    uint32_t background_color;
} relay_chromium_settings;

typedef enum relay_chromium_load_result {
    RELAY_CHROMIUM_LOADED = 0,
    RELAY_CHROMIUM_NOT_FOUND,
    /// The framework speaks a different API from the headers this build was
    /// compiled against.
    RELAY_CHROMIUM_INCOMPATIBLE,
} relay_chromium_load_result;

/// Loads the framework at `framework_path` and checks that it speaks the API
/// this build was compiled against.
relay_chromium_load_result relay_chromium_load(const char *framework_path);

/// Starts Chromium. Main thread only, after a successful load, and after the
/// application object exists. `schedule` is how Chromium asks for
/// `relay_chromium_do_work` to be called again, after `delay_ms`
/// milliseconds, and it may ask from any thread.
int relay_chromium_initialize(const relay_chromium_settings *settings, void (*schedule)(int64_t delay_ms));

/// One turn of Chromium's work on the main thread.
void relay_chromium_do_work(void);

/// Only once every browser has reported `closed`.
void relay_chromium_shutdown(void);

/// Creates a page in `parent_view`, an NSView, `width` by `height` points to
/// begin with. The handle belongs to the caller until it is passed to
/// `relay_chromium_browser_release`.
relay_chromium_browser *relay_chromium_browser_create(
    void *parent_view,
    int width,
    int height,
    const char *url,
    relay_chromium_callbacks callbacks
);

void relay_chromium_browser_load(relay_chromium_browser *browser, const char *url);
void relay_chromium_browser_go_back(relay_chromium_browser *browser);
void relay_chromium_browser_go_forward(relay_chromium_browser *browser);
void relay_chromium_browser_reload(relay_chromium_browser *browser, int ignore_cache);
void relay_chromium_browser_stop(relay_chromium_browser *browser);
void relay_chromium_browser_set_focus(relay_chromium_browser *browser, int focus);
void relay_chromium_browser_show_devtools(relay_chromium_browser *browser);

/// Hands a DevTools protocol message to the page. Returns 0 when there is no
/// page yet to take it.
int relay_chromium_browser_send_devtools_message(relay_chromium_browser *browser, const char *json, size_t length);

/// The NSView Chromium draws into, or NULL before `created`.
void *relay_chromium_browser_view(relay_chromium_browser *browser);

/// Starts taking the page down. `closed` follows, once.
void relay_chromium_browser_close(relay_chromium_browser *browser);

void relay_chromium_browser_release(relay_chromium_browser *browser);

/// The whole of a helper process: Chromium runs its renderers, its GPU
/// process and its utilities in copies of one small executable, and this is
/// that executable's `main`.
int relay_chromium_run_helper(int argc, char **argv);

#ifdef __cplusplus
}
#endif

#endif
