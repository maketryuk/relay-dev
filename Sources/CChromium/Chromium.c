#include "CChromium.h"
#include "ChromiumAppKit.h"

#include <crt_externs.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/cef_sandbox_mac.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"

// MARK: - The library

// CEF on macOS is loaded at run time rather than linked: the sandbox requires
// it, and it is also what lets `swift build` and the tests run on a machine
// that has never downloaded the framework. These are the entry points Relay
// uses, looked up once.
static struct {
    void *handle;
    __typeof__(cef_api_hash) *api_hash;
    __typeof__(cef_initialize) *initialize;
    __typeof__(cef_shutdown) *shutdown;
    __typeof__(cef_do_message_loop_work) *do_message_loop_work;
    __typeof__(cef_execute_process) *execute_process;
    __typeof__(cef_get_exit_code) *get_exit_code;
    __typeof__(cef_browser_host_create_browser) *create_browser;
    __typeof__(cef_string_utf8_to_utf16) *utf8_to_utf16;
    __typeof__(cef_string_utf16_to_utf8) *utf16_to_utf8;
    __typeof__(cef_string_utf16_clear) *utf16_clear;
    __typeof__(cef_string_utf8_clear) *utf8_clear;
    __typeof__(cef_string_userfree_utf16_free) *userfree_free;
} cef;

static void *symbol(const char *name, int *missing) {
    void *address = dlsym(cef.handle, name);
    if (!address) *missing = 1;
    return address;
}

relay_chromium_load_result relay_chromium_load(const char *framework_path) {
    if (cef.handle) return RELAY_CHROMIUM_LOADED;

    cef.handle = dlopen(framework_path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (!cef.handle) return RELAY_CHROMIUM_NOT_FOUND;

    int missing = 0;
    cef.api_hash = symbol("cef_api_hash", &missing);
    cef.initialize = symbol("cef_initialize", &missing);
    cef.shutdown = symbol("cef_shutdown", &missing);
    cef.do_message_loop_work = symbol("cef_do_message_loop_work", &missing);
    cef.execute_process = symbol("cef_execute_process", &missing);
    cef.get_exit_code = symbol("cef_get_exit_code", &missing);
    cef.create_browser = symbol("cef_browser_host_create_browser", &missing);
    cef.utf8_to_utf16 = symbol("cef_string_utf8_to_utf16", &missing);
    cef.utf16_to_utf8 = symbol("cef_string_utf16_to_utf8", &missing);
    cef.utf16_clear = symbol("cef_string_utf16_clear", &missing);
    cef.utf8_clear = symbol("cef_string_utf8_clear", &missing);
    cef.userfree_free = symbol("cef_string_userfree_utf16_free", &missing);

    // The hash names the exact layout of every structure in the headers this
    // file was compiled against. A framework that disagrees would read our
    // callbacks at the wrong offsets, so it is refused before anything else is
    // called.
    if (missing || strcmp(cef.api_hash(CEF_API_VERSION, 0), CEF_API_HASH_PLATFORM) != 0) {
        dlclose(cef.handle);
        memset(&cef, 0, sizeof(cef));
        return RELAY_CHROMIUM_INCOMPATIBLE;
    }
    return RELAY_CHROMIUM_LOADED;
}

// MARK: - Strings

static cef_string_t string_from(const char *text) {
    cef_string_t result = {0};
    if (text) cef.utf8_to_utf16(text, strlen(text), &result);
    return result;
}

/// A copy the caller frees.
static char *text_from(const cef_string_t *string) {
    if (!string || !string->str) return strdup("");
    cef_string_utf8_t converted = {0};
    cef.utf16_to_utf8(string->str, string->length, &converted);
    char *result = strndup(converted.str ? converted.str : "", converted.length);
    cef.utf8_clear(&converted);
    return result;
}

static void set_string(cef_string_t *field, const char *text) {
    if (text && *text) *field = string_from(text);
}

// MARK: - References

// The rules the C++ wrapper follows, and so the rules here: a structure passed
// as an argument carries a reference the receiver owns, in both directions,
// and so does a structure returned. `self` is the exception.
#define RELEASE(object)                                                        \
    do {                                                                       \
        if (object) (object)->base.release(&(object)->base);                   \
    } while (0)
#define ADD_REF(object) (object)->base.add_ref(&(object)->base)

// MARK: - The application

// Chromium's work is interleaved with AppKit's rather than given the thread:
// Relay's run loop is SwiftUI's, and Chromium asks for a turn when it has
// something to do.
static void (*schedule_work)(int64_t delay_ms);

static void CEF_CALLBACK static_add_ref(cef_base_ref_counted_t *self) { (void)self; }
static int CEF_CALLBACK static_release(cef_base_ref_counted_t *self) {
    (void)self;
    return 0;
}
static int CEF_CALLBACK static_has_one_ref(cef_base_ref_counted_t *self) {
    (void)self;
    return 1;
}

static void CEF_CALLBACK on_schedule_message_pump_work(cef_browser_process_handler_t *self, int64_t delay_ms) {
    (void)self;
    if (schedule_work) schedule_work(delay_ms);
}

static void append_switch(cef_command_line_t *command_line, const char *name, const char *value) {
    cef_string_t switch_name = string_from(name);
    if (value) {
        cef_string_t switch_value = string_from(value);
        command_line->append_switch_with_value(command_line, &switch_name, &switch_value);
        cef.utf16_clear(&switch_value);
    } else {
        command_line->append_switch(command_line, &switch_name);
    }
    cef.utf16_clear(&switch_name);
}

static void CEF_CALLBACK on_before_command_line_processing(
    cef_app_t *self,
    const cef_string_t *process_type,
    cef_command_line_t *command_line
) {
    (void)self;
    if (!process_type || process_type->length == 0) {
        // Chromium keeps the key it encrypts cookies with in the login
        // keychain, and macOS asks for permission to read it again every time
        // the app's signature changes — which, for a build signed on this
        // machine, is every build.
        append_switch(command_line, "use-mock-keychain", NULL);
        // Looking for screens to cast to means asking the local network, and
        // macOS asks the user first. Nobody casts a development server.
        append_switch(command_line, "disable-features", "MediaRouter");
    }
    RELEASE(command_line);
}

static cef_browser_process_handler_t browser_process_handler;

static cef_browser_process_handler_t *CEF_CALLBACK get_browser_process_handler(cef_app_t *self) {
    (void)self;
    return &browser_process_handler;
}

static cef_app_t application;

int relay_chromium_initialize(const relay_chromium_settings *settings, void (*schedule)(int64_t delay_ms)) {
    if (!cef.handle) return 0;
    schedule_work = schedule;
    relay_chromium_prepare_application();

    browser_process_handler.base.size = sizeof(browser_process_handler);
    browser_process_handler.base.add_ref = static_add_ref;
    browser_process_handler.base.release = static_release;
    browser_process_handler.base.has_one_ref = static_has_one_ref;
    browser_process_handler.base.has_at_least_one_ref = static_has_one_ref;
    browser_process_handler.on_schedule_message_pump_work = on_schedule_message_pump_work;

    application.base.size = sizeof(application);
    application.base.add_ref = static_add_ref;
    application.base.release = static_release;
    application.base.has_one_ref = static_has_one_ref;
    application.base.has_at_least_one_ref = static_has_one_ref;
    application.on_before_command_line_processing = on_before_command_line_processing;
    application.get_browser_process_handler = get_browser_process_handler;

    cef_settings_t cef_settings = {0};
    cef_settings.size = sizeof(cef_settings);
    cef_settings.external_message_pump = 1;
    // Relay's own arguments are SwiftUI's business, not Chromium's.
    cef_settings.command_line_args_disabled = 1;
    // Chromium's crash handlers would otherwise replace the ones the process
    // already has.
    cef_settings.disable_signal_handlers = 1;
    cef_settings.persist_session_cookies = 1;
    cef_settings.log_severity = LOGSEVERITY_WARNING;
    cef_settings.background_color = settings->background_color;
    set_string(&cef_settings.main_bundle_path, settings->main_bundle_path);
    set_string(&cef_settings.framework_dir_path, settings->framework_path);
    set_string(&cef_settings.browser_subprocess_path, settings->helper_path);
    set_string(&cef_settings.root_cache_path, settings->cache_path);
    set_string(&cef_settings.cache_path, settings->cache_path);
    set_string(&cef_settings.log_file, settings->log_path);
    set_string(&cef_settings.locale, settings->locale);

    cef_main_args_t arguments = {*_NSGetArgc(), *_NSGetArgv()};
    int succeeded = cef.initialize(&arguments, &cef_settings, &application, NULL);

    cef.utf16_clear(&cef_settings.main_bundle_path);
    cef.utf16_clear(&cef_settings.framework_dir_path);
    cef.utf16_clear(&cef_settings.browser_subprocess_path);
    cef.utf16_clear(&cef_settings.root_cache_path);
    cef.utf16_clear(&cef_settings.cache_path);
    cef.utf16_clear(&cef_settings.log_file);
    cef.utf16_clear(&cef_settings.locale);
    return succeeded;
}

void relay_chromium_do_work(void) {
    if (cef.handle) cef.do_message_loop_work();
}

void relay_chromium_shutdown(void) {
    if (cef.handle) cef.shutdown();
}

// MARK: - A page

// One allocation holds the client and every handler it hands out, sharing one
// count: CEF may keep any of them after the others, and the page is gone only
// when the last is released.
struct relay_chromium_browser {
    cef_client_t client;
    cef_life_span_handler_t life_span;
    cef_display_handler_t display;
    cef_load_handler_t load;
    cef_request_handler_t request;
    cef_focus_handler_t focus;
    cef_dev_tools_message_observer_t devtools;
    atomic_int references;

    relay_chromium_callbacks callbacks;
    /// The page itself, from `on_after_created` to `on_before_close`.
    cef_browser_t *browser;
    int identifier;
    cef_registration_t *devtools_registration;
    int close_requested;
};

#define OWNER(pointer, member)                                                 \
    ((relay_chromium_browser *)((char *)(pointer) - offsetof(relay_chromium_browser, member)))

static void retain(relay_chromium_browser *owner) {
    atomic_fetch_add(&owner->references, 1);
}

static int release(relay_chromium_browser *owner) {
    if (atomic_fetch_sub(&owner->references, 1) != 1) return 0;
    free(owner);
    return 1;
}

#define REFERENCE_COUNTING(member)                                             \
    static void CEF_CALLBACK member##_add_ref(cef_base_ref_counted_t *self) {  \
        retain(OWNER(self, member));                                           \
    }                                                                          \
    static int CEF_CALLBACK member##_release(cef_base_ref_counted_t *self) {   \
        return release(OWNER(self, member));                                   \
    }                                                                          \
    static int CEF_CALLBACK member##_has_one_ref(cef_base_ref_counted_t *self) { \
        return atomic_load(&OWNER(self, member)->references) == 1;            \
    }                                                                          \
    static int CEF_CALLBACK member##_has_at_least_one_ref(cef_base_ref_counted_t *self) { \
        return atomic_load(&OWNER(self, member)->references) >= 1;            \
    }

#define INSTALL_REFERENCE_COUNTING(owner, member)                              \
    do {                                                                       \
        (owner)->member.base.size = sizeof((owner)->member);                   \
        (owner)->member.base.add_ref = member##_add_ref;                       \
        (owner)->member.base.release = member##_release;                       \
        (owner)->member.base.has_one_ref = member##_has_one_ref;               \
        (owner)->member.base.has_at_least_one_ref = member##_has_at_least_one_ref; \
    } while (0)

REFERENCE_COUNTING(client)
REFERENCE_COUNTING(life_span)
REFERENCE_COUNTING(display)
REFERENCE_COUNTING(load)
REFERENCE_COUNTING(request)
REFERENCE_COUNTING(focus)
REFERENCE_COUNTING(devtools)

/// Whether a callback is about the page, rather than a popup or a DevTools
/// window that inherited its client.
static int is_page(relay_chromium_browser *owner, cef_browser_t *browser) {
    return owner->browser && browser && browser->get_identifier(browser) == owner->identifier;
}

// MARK: Handlers handed out by the client

#define GETTER(member, type)                                                   \
    static type *CEF_CALLBACK get_##member##_handler(cef_client_t *self) {     \
        relay_chromium_browser *owner = OWNER(self, client);                  \
        ADD_REF(&owner->member);                                               \
        return &owner->member;                                                 \
    }

GETTER(life_span, cef_life_span_handler_t)
GETTER(display, cef_display_handler_t)
GETTER(load, cef_load_handler_t)
GETTER(request, cef_request_handler_t)
GETTER(focus, cef_focus_handler_t)

// MARK: Life span

static int CEF_CALLBACK on_before_popup(
    cef_life_span_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    int popup_id,
    const cef_string_t *target_url,
    const cef_string_t *target_frame_name,
    cef_window_open_disposition_t target_disposition,
    int user_gesture,
    const cef_popup_features_t *popup_features,
    cef_window_info_t *window_info,
    cef_client_t **client,
    cef_browser_settings_t *settings,
    cef_dictionary_value_t **extra_info,
    int *no_javascript_access
) {
    (void)popup_id;
    (void)target_frame_name;
    (void)user_gesture;
    (void)popup_features;
    (void)window_info;
    (void)client;
    (void)settings;
    (void)extra_info;
    (void)no_javascript_access;
    relay_chromium_browser *owner = OWNER(self, life_span);
    int cancels = 0;
    // A link that asks for a tab is handed back, since a pane has no tabs. A
    // script's popup keeps its window: sign-in flows talk to their opener, and
    // opening one somewhere else breaks exactly that.
    switch (target_disposition) {
        case CEF_WOD_NEW_FOREGROUND_TAB:
        case CEF_WOD_NEW_BACKGROUND_TAB:
        case CEF_WOD_NEW_WINDOW:
        case CEF_WOD_SINGLETON_TAB:
        case CEF_WOD_SWITCH_TO_TAB:
            if (owner->callbacks.opens_in_new_tab) {
                char *url = text_from(target_url);
                owner->callbacks.opens_in_new_tab(owner->callbacks.context, url);
                free(url);
            }
            cancels = 1;
            break;
        default:
            break;
    }
    RELEASE(frame);
    RELEASE(browser);
    return cancels;
}

static void CEF_CALLBACK on_after_created(cef_life_span_handler_t *self, cef_browser_t *browser) {
    relay_chromium_browser *owner = OWNER(self, life_span);
    if (owner->browser) {
        RELEASE(browser);
        return;
    }
    owner->browser = browser;
    owner->identifier = browser->get_identifier(browser);

    cef_browser_host_t *host = browser->get_host(browser);
    ADD_REF(&owner->devtools);
    owner->devtools_registration = host->add_dev_tools_message_observer(host, &owner->devtools);
    // Closed before it had finished opening: the request waited for a page to
    // close, and there is one now.
    if (owner->close_requested) host->close_browser(host, 1);
    RELEASE(host);

    if (!owner->close_requested && owner->callbacks.created) owner->callbacks.created(owner->callbacks.context);
}

static int CEF_CALLBACK do_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    relay_chromium_browser *owner = OWNER(self, life_span);
    // Answering "no" here makes CEF send `performClose:` to the page's
    // window, which for a page in a pane is Relay's only window. The page's
    // own view is taken away instead. A popup or an inspector is in a window
    // CEF made for it, and closing that window is exactly right.
    int handled = is_page(owner, browser);
    if (handled) {
        cef_browser_host_t *host = browser->get_host(browser);
        relay_chromium_remove_view_later(host->get_window_handle(host));
        RELEASE(host);
    }
    RELEASE(browser);
    return handled;
}

static void CEF_CALLBACK on_before_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    relay_chromium_browser *owner = OWNER(self, life_span);
    if (!is_page(owner, browser)) {
        RELEASE(browser);
        return;
    }
    RELEASE(browser);

    RELEASE(owner->devtools_registration);
    owner->devtools_registration = NULL;
    RELEASE(owner->browser);
    owner->browser = NULL;

    relay_chromium_callbacks callbacks = owner->callbacks;
    memset(&owner->callbacks, 0, sizeof(owner->callbacks));
    if (callbacks.closed) callbacks.closed(callbacks.context);
}

// MARK: Display

static void CEF_CALLBACK on_address_change(
    cef_display_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    const cef_string_t *url
) {
    relay_chromium_browser *owner = OWNER(self, display);
    if (is_page(owner, browser) && frame->is_main(frame) && owner->callbacks.address_changed) {
        char *text = text_from(url);
        owner->callbacks.address_changed(owner->callbacks.context, text);
        free(text);
    }
    RELEASE(frame);
    RELEASE(browser);
}

static void CEF_CALLBACK on_title_change(cef_display_handler_t *self, cef_browser_t *browser, const cef_string_t *title) {
    relay_chromium_browser *owner = OWNER(self, display);
    if (is_page(owner, browser) && owner->callbacks.title_changed) {
        char *text = text_from(title);
        owner->callbacks.title_changed(owner->callbacks.context, text);
        free(text);
    }
    RELEASE(browser);
}

// MARK: Load

static void CEF_CALLBACK on_loading_state_change(
    cef_load_handler_t *self,
    cef_browser_t *browser,
    int is_loading,
    int can_go_back,
    int can_go_forward
) {
    relay_chromium_browser *owner = OWNER(self, load);
    if (is_page(owner, browser) && owner->callbacks.loading_changed) {
        owner->callbacks.loading_changed(owner->callbacks.context, is_loading, can_go_back, can_go_forward);
    }
    RELEASE(browser);
}

static void CEF_CALLBACK on_load_error(
    cef_load_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    cef_errorcode_t error_code,
    const cef_string_t *error_text,
    const cef_string_t *failed_url
) {
    relay_chromium_browser *owner = OWNER(self, load);
    // An abort is a navigation that was replaced by another — typing a new
    // address while the last one loads — not a failure worth a word.
    if (is_page(owner, browser) && frame->is_main(frame) && error_code != ERR_ABORTED && owner->callbacks.load_failed) {
        char *text = text_from(error_text);
        char *url = text_from(failed_url);
        owner->callbacks.load_failed(owner->callbacks.context, error_code, text, url);
        free(text);
        free(url);
    }
    RELEASE(frame);
    RELEASE(browser);
}

// MARK: Request

static void CEF_CALLBACK on_render_process_terminated(
    cef_request_handler_t *self,
    cef_browser_t *browser,
    cef_termination_status_t status,
    int error_code,
    const cef_string_t *error_string
) {
    (void)error_code;
    (void)error_string;
    relay_chromium_browser *owner = OWNER(self, request);
    if (is_page(owner, browser) && owner->callbacks.renderer_gone) {
        owner->callbacks.renderer_gone(owner->callbacks.context, (int)status);
    }
    RELEASE(browser);
}

// MARK: Focus

static void CEF_CALLBACK on_got_focus(cef_focus_handler_t *self, cef_browser_t *browser) {
    relay_chromium_browser *owner = OWNER(self, focus);
    if (is_page(owner, browser) && owner->callbacks.focused) owner->callbacks.focused(owner->callbacks.context);
    RELEASE(browser);
}

// MARK: DevTools

static int CEF_CALLBACK on_dev_tools_message(
    cef_dev_tools_message_observer_t *self,
    cef_browser_t *browser,
    const void *message,
    size_t message_size
) {
    relay_chromium_browser *owner = OWNER(self, devtools);
    if (is_page(owner, browser) && owner->callbacks.devtools_message) {
        owner->callbacks.devtools_message(owner->callbacks.context, message, message_size);
    }
    RELEASE(browser);
    return 1;
}

// MARK: Creating and driving a page

relay_chromium_browser *relay_chromium_browser_create(
    void *parent_view,
    int width,
    int height,
    const char *url,
    relay_chromium_callbacks callbacks
) {
    if (!cef.handle) return NULL;

    relay_chromium_browser *owner = calloc(1, sizeof(*owner));
    if (!owner) return NULL;
    // The caller's reference.
    atomic_init(&owner->references, 1);
    owner->callbacks = callbacks;

    INSTALL_REFERENCE_COUNTING(owner, client);
    owner->client.get_life_span_handler = get_life_span_handler;
    owner->client.get_display_handler = get_display_handler;
    owner->client.get_load_handler = get_load_handler;
    owner->client.get_request_handler = get_request_handler;
    owner->client.get_focus_handler = get_focus_handler;

    INSTALL_REFERENCE_COUNTING(owner, life_span);
    owner->life_span.on_before_popup = on_before_popup;
    owner->life_span.on_after_created = on_after_created;
    owner->life_span.do_close = do_close;
    owner->life_span.on_before_close = on_before_close;

    INSTALL_REFERENCE_COUNTING(owner, display);
    owner->display.on_address_change = on_address_change;
    owner->display.on_title_change = on_title_change;

    INSTALL_REFERENCE_COUNTING(owner, load);
    owner->load.on_loading_state_change = on_loading_state_change;
    owner->load.on_load_error = on_load_error;

    INSTALL_REFERENCE_COUNTING(owner, request);
    owner->request.on_render_process_terminated = on_render_process_terminated;

    INSTALL_REFERENCE_COUNTING(owner, focus);
    owner->focus.on_got_focus = on_got_focus;

    INSTALL_REFERENCE_COUNTING(owner, devtools);
    owner->devtools.on_dev_tools_message = on_dev_tools_message;

    cef_window_info_t window_info = {0};
    window_info.size = sizeof(window_info);
    window_info.parent_view = parent_view;
    window_info.bounds.width = width;
    window_info.bounds.height = height;
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    cef_browser_settings_t browser_settings = {0};
    browser_settings.size = sizeof(browser_settings);

    cef_string_t address = string_from(url);
    ADD_REF(&owner->client);
    int started = cef.create_browser(&window_info, &owner->client, &address, &browser_settings, NULL, NULL);
    cef.utf16_clear(&address);

    if (!started) {
        // CEF took the reference it was given whatever it answered, and gives
        // it back when it lets go; only the caller's is ours to drop.
        release(owner);
        return NULL;
    }
    return owner;
}

/// The page's host, with a reference the caller releases, or NULL.
static cef_browser_host_t *host_of(relay_chromium_browser *owner) {
    if (!owner || !owner->browser) return NULL;
    return owner->browser->get_host(owner->browser);
}

void relay_chromium_browser_load(relay_chromium_browser *owner, const char *url) {
    if (!owner || !owner->browser) return;
    cef_frame_t *frame = owner->browser->get_main_frame(owner->browser);
    if (!frame) return;
    cef_string_t address = string_from(url);
    frame->load_url(frame, &address);
    cef.utf16_clear(&address);
    RELEASE(frame);
}

void relay_chromium_browser_go_back(relay_chromium_browser *owner) {
    if (owner && owner->browser) owner->browser->go_back(owner->browser);
}

void relay_chromium_browser_go_forward(relay_chromium_browser *owner) {
    if (owner && owner->browser) owner->browser->go_forward(owner->browser);
}

void relay_chromium_browser_reload(relay_chromium_browser *owner, int ignore_cache) {
    if (!owner || !owner->browser) return;
    if (ignore_cache) {
        owner->browser->reload_ignore_cache(owner->browser);
    } else {
        owner->browser->reload(owner->browser);
    }
}

void relay_chromium_browser_stop(relay_chromium_browser *owner) {
    if (owner && owner->browser) owner->browser->stop_load(owner->browser);
}

void relay_chromium_browser_set_focus(relay_chromium_browser *owner, int focus) {
    cef_browser_host_t *host = host_of(owner);
    if (!host) return;
    host->set_focus(host, focus);
    RELEASE(host);
}

void relay_chromium_browser_show_devtools(relay_chromium_browser *owner) {
    cef_browser_host_t *host = host_of(owner);
    if (!host) return;
    // A window of its own, the way a browser's inspector opens undocked: the
    // pane is usually narrow already, and the inspector wants the room.
    cef_window_info_t window_info = {0};
    window_info.size = sizeof(window_info);
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    cef_browser_settings_t browser_settings = {0};
    browser_settings.size = sizeof(browser_settings);
    host->show_dev_tools(host, &window_info, NULL, &browser_settings, NULL);
    RELEASE(host);
}

int relay_chromium_browser_send_devtools_message(relay_chromium_browser *owner, const char *json, size_t length) {
    cef_browser_host_t *host = host_of(owner);
    if (!host) return 0;
    int sent = host->send_dev_tools_message(host, json, length);
    RELEASE(host);
    return sent;
}

void *relay_chromium_browser_view(relay_chromium_browser *owner) {
    cef_browser_host_t *host = host_of(owner);
    if (!host) return NULL;
    void *view = host->get_window_handle(host);
    RELEASE(host);
    return view;
}

void relay_chromium_browser_close(relay_chromium_browser *owner) {
    if (!owner || owner->close_requested) return;
    owner->close_requested = 1;
    cef_browser_host_t *host = host_of(owner);
    // Not created yet: `on_after_created` sees the request and closes it then.
    if (!host) return;
    host->close_browser(host, 1);
    RELEASE(host);
}

void relay_chromium_browser_release(relay_chromium_browser *owner) {
    if (owner) release(owner);
}

// MARK: - The helper

int relay_chromium_run_helper(int argc, char **argv) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return 1;
    // `Relay Helper.app/Contents/MacOS`, three levels inside the Frameworks
    // directory the framework sits in.
    const char *directory = dirname(executable);
    char path[PATH_MAX];

    // The sandbox first and the framework after, the order CEF's own helper
    // keeps (`include/wrapper/cef_library_loader.h`).
    snprintf(path, sizeof(path), "%s/../../../Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib", directory);
    void *sandbox_library = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    __typeof__(cef_sandbox_initialize) *initialize_sandbox =
        sandbox_library ? dlsym(sandbox_library, "cef_sandbox_initialize") : NULL;
    __typeof__(cef_sandbox_destroy) *destroy_sandbox =
        sandbox_library ? dlsym(sandbox_library, "cef_sandbox_destroy") : NULL;
    void *sandbox = initialize_sandbox ? initialize_sandbox(argc, argv) : NULL;
    if (!sandbox) {
        fprintf(stderr, "Relay Helper: the Chromium sandbox could not be started.\n");
        return 1;
    }

    snprintf(path, sizeof(path), "%s/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework", directory);
    switch (relay_chromium_load(path)) {
        case RELAY_CHROMIUM_LOADED:
            break;
        case RELAY_CHROMIUM_NOT_FOUND:
            fprintf(stderr, "Relay Helper: the Chromium framework could not be loaded.\n");
            return 1;
        case RELAY_CHROMIUM_INCOMPATIBLE:
            fprintf(stderr, "Relay Helper: the Chromium framework is not the version Relay was built for.\n");
            return 1;
    }

    cef_main_args_t arguments = {argc, argv};
    int code = cef.execute_process(&arguments, NULL, NULL);
    if (destroy_sandbox) destroy_sandbox(sandbox);
    return code;
}
