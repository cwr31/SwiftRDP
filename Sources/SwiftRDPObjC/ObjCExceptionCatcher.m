#import "ObjCExceptionCatcher.h"

NSString * _Nullable MHRDPCatchObjCException(void (^ _Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name ?: @"unknown ObjC exception";
    }
}
