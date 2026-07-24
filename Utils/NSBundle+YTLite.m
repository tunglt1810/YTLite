#import "NSBundle+YTLite.h"

#ifndef jbroot
#define jbroot(path) path
#endif

@implementation NSBundle (YTLite)

+ (NSBundle *)ytl_defaultBundle {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"YTLite" ofType:@"bundle"];
        if (!bundlePath) {
            bundlePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"YTLite.bundle"];
        }
        if (!bundlePath || ![[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            bundlePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/YTLite.bundle"];
        }
        if (!bundlePath || ![[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            bundlePath = jbroot(@"/Library/Application Support/YTLite.bundle");
        }
        bundle = [NSBundle bundleWithPath:bundlePath] ?: [NSBundle mainBundle];
    });

    return bundle;
}

+ (NSString *)ytl_localizedStringForKey:(NSString *)key {
    NSString *val = [self.ytl_defaultBundle localizedStringForKey:key value:nil table:nil];
    return val ?: key;
}

@end
