#import <Foundation/Foundation.h>

/// Run `block` catching any Objective-C NSException.
/// Returns nil on success; returns the exception reason string on failure.
NSString * _Nullable MHRDPCatchObjCException(void (^ _Nonnull block)(void));
