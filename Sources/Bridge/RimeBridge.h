#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface LIRime : NSObject
+ (void)startShared:(NSString *)shared user:(NSString *)user deploy:(BOOL)deploy;
// Marks every open session stale. Rime reads the custom phrase table when a
// session is created, so the next -open is what picks up an edited word list.
+ (void)invalidateSessions;
+ (void)shutdown;
- (BOOL)open;
- (BOOL)process:(int)key modifiers:(int)modifiers;
- (NSDictionary *)snapshot;
- (NSString *)takeCommit;
- (NSString *)rawInput;
- (NSString *)takeRawInput;
- (void)clear;
- (void)commit;
- (void)select:(NSUInteger)index;
@end
NS_ASSUME_NONNULL_END
