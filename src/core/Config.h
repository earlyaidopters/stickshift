#import <Foundation/Foundation.h>
#import "AXState.h"

// A resolved (model, effort) target for one agent kind.
@interface GearTuple : NSObject
@property(nonatomic, copy) NSString *model;   // display/inline value per spike 7
@property(nonatomic, copy) NSString *effort;  // may be nil (model-only)
@end

typedef NS_ENUM(NSInteger, DialogPolicy) { DialogAsk = 0, DialogConfirm, DialogCancel };

@interface Config : NSObject
@property(nonatomic) DialogPolicy dialogPolicy;
@property(nonatomic) BOOL autoAnswerEnabled;    // ships off
@property(nonatomic, strong) NSArray<NSString*> *enabledTerminals; // bundle ids
@property(nonatomic) BOOL loadedFromFile;
@property(nonatomic) BOOL malformed;
@property(nonatomic, copy) NSString *loadError;
// gear ("1".."5","R","ULTRA") -> per-agent tuple
- (GearTuple *)tupleForGear:(NSString *)gear kind:(AgentKind)kind;
- (NSArray<NSString*> *)allGears;
+ (instancetype)load;     // ~/.stickshift/config.toml or built-in defaults
+ (instancetype)defaults; // built-in defaults only
+ (NSString *)configPath; // honors STICKSHIFT_CONFIG env override (tests)
// Upsert dialog_policy + auto_answer into config.toml, preserving any other lines.
- (BOOL)persistPolicy:(NSString **)err;
// strict charset for any value that becomes a keystroke (PLAN item 11)
+ (BOOL)isInjectionSafe:(NSString *)s;
@end
