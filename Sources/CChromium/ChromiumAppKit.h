#ifndef RELAY_CHROMIUM_APPKIT_H
#define RELAY_CHROMIUM_APPKIT_H

// The little AppKit that `Chromium.c` needs, kept in Objective-C where it can
// be written plainly.

/// Makes the application answer what CEF asks of every host's application
/// class (`include/cef_application_mac.h`): whether `-sendEvent:` is on the
/// stack, which Chromium uses to tell a nested run loop from the top-level
/// one, and which a plain NSApplication cannot say.
///
/// Added to the class the application already is rather than by naming a
/// subclass in the Info.plist, because SwiftUI makes the application from a
/// private subclass of its own and never reads `NSPrincipalClass`.
void relay_chromium_prepare_application(void);

/// Takes a page's view out of the window on the next turn of the main queue.
///
/// This is how a page in a pane is closed. CEF's default is to ask the view's
/// window to close — Relay's own window — and the view going away is the
/// other signal it accepts: it destroys the page when its view is released.
/// Not within the callback that asked, because the page would then be
/// destroyed underneath CEF's own stack.
void relay_chromium_remove_view_later(void *view);

#endif
