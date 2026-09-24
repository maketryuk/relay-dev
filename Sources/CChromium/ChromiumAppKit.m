#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "ChromiumAppKit.h"

// Copies of the protocols in CEF's `include/cef_application_mac.h`. The
// runtime matches protocols by name, so declaring them here is what makes
// Chromium's `conformsToProtocol:` see the ones it looks for.
@protocol CrAppProtocol
- (BOOL)isHandlingSendEvent;
@end

@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

@protocol CefAppProtocol <CrAppControlProtocol>
@end

/// Whether `-sendEvent:` is on the stack. One application, so one flag.
static BOOL handlingSendEvent;

void relay_chromium_prepare_application(void) {
    NSApplication *application = [NSApplication sharedApplication];
    if ([application conformsToProtocol:@protocol(CefAppProtocol)]) return;

    // The class SwiftUI made the application from — its own private
    // subclass, whatever the Info.plist names — is given what CEF asks of a
    // host's application class rather than being replaced by one.
    Class type = object_getClass(application);

    struct objc_method_description getter =
        protocol_getMethodDescription(@protocol(CrAppProtocol), @selector(isHandlingSendEvent), YES, YES);
    class_addMethod(type, @selector(isHandlingSendEvent), imp_implementationWithBlock(^BOOL(id self) {
        return handlingSendEvent;
    }), getter.types);

    struct objc_method_description setter =
        protocol_getMethodDescription(@protocol(CrAppControlProtocol), @selector(setHandlingSendEvent:), YES, YES);
    class_addMethod(type, @selector(setHandlingSendEvent:), imp_implementationWithBlock(^(id self, BOOL value) {
        handlingSendEvent = value;
    }), setter.types);

    // Restored rather than cleared: an event handled inside a nested run loop
    // returns to an outer `sendEvent:` that is still on the stack.
    Method sendEvent = class_getInstanceMethod(type, @selector(sendEvent:));
    IMP original = method_getImplementation(sendEvent);
    IMP wrapped = imp_implementationWithBlock(^(id self, NSEvent *event) {
        BOOL wasHandling = handlingSendEvent;
        handlingSendEvent = YES;
        ((void (*)(id, SEL, NSEvent *))original)(self, @selector(sendEvent:), event);
        handlingSendEvent = wasHandling;
    });
    // Added when the class inherits the method, so the superclass is left
    // alone; replaced when the class has its own.
    if (!class_addMethod(type, @selector(sendEvent:), wrapped, method_getTypeEncoding(sendEvent))) {
        method_setImplementation(sendEvent, wrapped);
    }

    class_addProtocol(type, @protocol(CrAppProtocol));
    class_addProtocol(type, @protocol(CrAppControlProtocol));
    class_addProtocol(type, @protocol(CefAppProtocol));
}

void relay_chromium_remove_view_later(void *view) {
    if (!view) return;
    NSView *page = (__bridge NSView *)view;
    dispatch_async(dispatch_get_main_queue(), ^{
        [page removeFromSuperview];
    });
}
