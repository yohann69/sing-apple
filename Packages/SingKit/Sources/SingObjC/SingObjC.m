#import "SingObjC.h"

BOOL SingTryObjC(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"SingObjC" code:1 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}
