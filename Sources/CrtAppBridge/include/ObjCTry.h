#ifndef CRT_OBJC_TRY_H
#define CRT_OBJC_TRY_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns nil, or the reason of the Objective-C
/// exception it raised. Swift can't catch those, and one that escapes on
/// the main thread is swallowed by AppKit along with whatever Swift task was
/// running (AVPlayer raises them for calls made in the wrong state).
NSString * _Nullable CrtCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

#endif
