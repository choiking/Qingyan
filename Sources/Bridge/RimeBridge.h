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
- (NSArray<NSString *> *)candidatePool:(NSUInteger)limit;
// Bounded window for the candidate grid; never commits or changes highlight.
- (NSArray<NSString *> *)candidatesFrom:(NSUInteger)start limit:(NSUInteger)limit;
// Each item: text, coverageEnd (byte offset in raw input), remainingInput.
// Returns an empty array when exact coverage cannot be established.
- (NSArray<NSDictionary *> *)candidateDetails:(NSUInteger)limit;
- (void)selectGlobal:(NSUInteger)index;
// Highlight without committing; returns NO when the candidate does not exist.
- (BOOL)highlightGlobal:(NSUInteger)index;
@end
NS_ASSUME_NONNULL_END
