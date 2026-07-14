#import <Foundation/Foundation.h>
#import "AXState.h"

// A qualified agent identity + protocol, from spikes 5/7. Keyed on code signature
// (team + identifier) and adjacent package version, never by executing the binary.
@interface AgentIdentity : NSObject
@property(nonatomic) AgentKind kind;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *teamId;
@property(nonatomic, copy) NSString *codeId;
@property(nonatomic, copy) NSString *version;      // resolved from adjacent package.json
@property(nonatomic, copy) NSString *imagePath;
@property(nonatomic) BOOL signatureValid;
@property(nonatomic) BOOL qualified;               // in the manifest's qualified set
@end

@interface Manifest : NSObject
+ (instancetype)shared;
// Derive identity for a running agent process image WITHOUT executing it.
// imagePath is the fg leader's image (or, for codex, the signed native child image).
- (AgentIdentity *)identifyImage:(NSString *)imagePath kindHint:(AgentKind)hint;
// Nearest-ancestor package.json version (claude: 1 level up; codex: 3 levels up —
// vendor/<triple>/bin/). Exposed for tests.
- (NSString *)versionFromImage:(NSString *)imagePath kind:(AgentKind)kind;
// Is (agent, model, effort) a qualified tuple? (nil effort = model-only)
- (BOOL)isTupleQualifiedForKind:(AgentKind)kind model:(NSString *)model effort:(NSString *)effort;
@end
