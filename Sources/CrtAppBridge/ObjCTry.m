#import "include/ObjCTry.h"

NSString * _Nullable CrtCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e.reason ?: e.name;
    }
}
