#import <Foundation/Foundation.h>
#import "AXState.h"

// How the resolved version relates to the manifest's known-good set. Identity
// (signature + team + code id) is always a HARD gate; version is a drift signal:
// agents update weekly, and every UI interaction is independently re-proven at
// runtime (classifier must parse, picker rows are label-verified, delivery is
// occurrence-counted), so an unknown-but-authentic version is driven with the
// runtime proofs as the safety net rather than refused outright.
typedef NS_ENUM(NSInteger, VersionMatch) {
    VersionUnknown = 0,   // no version resolved from package.json
    VersionExact,         // in the qualified set
    VersionSameSeries,    // same major.minor as a qualified version (patch drift)
    VersionDrift,         // authentic binary, out-of-series version — log a warning
};

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
@property(nonatomic) VersionMatch versionMatch;
@property(nonatomic) BOOL qualified;               // signature+team+id valid, kind known
@end

@interface Manifest : NSObject
+ (instancetype)shared;
// Derive identity for a running agent process image WITHOUT executing it.
// imagePath is the fg leader's image (or, for codex, the signed native child image).
- (AgentIdentity *)identifyImage:(NSString *)imagePath kindHint:(AgentKind)hint;
// Nearest-ancestor package.json version (claude: 1 level up; codex: 3 levels up —
// vendor/<triple>/bin/). Exposed for tests.
- (NSString *)versionFromImage:(NSString *)imagePath kind:(AgentKind)kind;
// Pure version-drift policy (exposed for tests): how does v relate to the
// qualified set for this kind?
+ (VersionMatch)matchForVersion:(NSString *)v kind:(AgentKind)kind;
// Is (agent, model, effort) a qualified tuple? (nil effort = model-only)
- (BOOL)isTupleQualifiedForKind:(AgentKind)kind model:(NSString *)model effort:(NSString *)effort;
@end
