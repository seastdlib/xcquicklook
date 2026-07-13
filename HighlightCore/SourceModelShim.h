#ifndef SourceModelShim_h
#define SourceModelShim_h

#import <Foundation/Foundation.h>

// Typed views onto Xcode's private SourceModel.framework, which is loaded at
// runtime with Bundle.load(); nothing here is linked. Only protocols are
// declared (never @interface) so no class symbols are referenced at link time.
// Objects obtained via NSClassFromString are unsafeBitCast to these protocol
// existentials after a respondsToSelector: capability probe.
//
// Selectors and type encodings were captured from the runtime on Xcode 27
// (see SourceModelClient.swift for the probe that revalidates them on load).

NS_ASSUME_NONNULL_BEGIN

/// What -[SMSourceModel initWithSourceBufferProvider:] requires of its buffer
/// provider (discovered empirically; there is no registered runtime protocol).
@protocol XCQLBufferProviding
// Typed id so the Swift implementation can hand back its stored NSString
// without bridging on every parser callback.
- (id)stringAsId;
- (NSUInteger)length;
- (nullable id)language;
- (NSRange)lineRangeForCharacterRange:(NSRange)range;
- (void)scheduleLazyInvalidationForRange:(NSRange)range;
@end

/// Class-side interface of SMSourceCodeLanguage (messages sent to the class object).
@protocol XCQLSourceCodeLanguageClass
- (void)loadAndCacheDefaultSourceCodeLanguages;
- (nullable id)sourceCodeLanguageForFileExtension:(NSString *)fileExtension;
- (nullable id)sourceCodeLanguageForFileDataTypeIdentifier:(NSString *)identifier;
- (nullable id)sourceCodeLanguageWithIdentifier:(NSString *)identifier;
@end

/// Class-side interface of SMSourceModel.
@protocol XCQLSourceModelClass
// Both alloc and init are stripped of their ObjC method families so ARC
// treats them as ordinary +0 calls: alloc's real (untracked) +1 is exactly
// consumed by init's real consumes-self, so the pair nets out balanced.
- (id)alloc __attribute__((objc_method_family(none)));
@end

/// Instance-side interface of SMSourceModel.
@protocol XCQLSourceModel
- (nullable id)initWithSourceBufferProvider:(id)provider
    NS_SWIFT_NAME(initialized(provider:))
    __attribute__((objc_method_family(none)));
- (void)setDirtyRange:(NSRange)range;
- (void)parse;
- (nullable id)_topLevelSourceItem;
@end

/// Instance-side interface of SMSourceModelItem.
@protocol XCQLSourceModelItem
- (NSRange)range;
- (int16_t)nodeType;
- (nullable NSArray *)children;
@end

/// Class-side interface of SMSourceNodeTypes.
@protocol XCQLSourceNodeTypesClass
- (nullable NSString *)nodeTypeNameForId:(int16_t)nodeTypeId;
@end

NS_ASSUME_NONNULL_END

#endif /* SourceModelShim_h */
