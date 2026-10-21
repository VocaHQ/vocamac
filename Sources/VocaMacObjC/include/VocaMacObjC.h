// VocaMacObjC.h
// VocaMac
//
// Objective-C helpers used by the Swift app.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VocaObjCExceptionCatcher : NSObject

/// Executes a block and converts any Objective-C NSException into an NSError.
///
/// Some AVFoundation APIs, including AVAudioNode tap installation, report
/// programmer/precondition failures by raising NSException instead of throwing
/// Swift/Objective-C NSError values. Swift cannot catch NSException directly,
/// so this helper prevents those framework exceptions from aborting the app.
+ (NSError * _Nullable)catchException:(NS_NOESCAPE void (^)(void))block;

@end

/// bzip2 decompression with the system libbz2.
///
/// The App Store build can't run /usr/bin/tar, so it unpacks the .tar.bz2
/// model archives itself: this turns an archive into a plain tar file, and
/// `TarArchive` reads that.
@interface VocaBZip2 : NSObject

/// Writes the decompressed contents of `sourcePath` (one or more bzip2
/// streams) to `destinationPath`, replacing any file there.
///
/// @param shouldCancel Asked before each chunk; returning YES stops with an error.
/// @return NO with `error` set when the input can't be read or is truncated
///   or corrupt, the output can't be written, or `shouldCancel` returned YES.
///   A partly written output file is removed.
+ (BOOL)decompressFileAtPath:(NSString *)sourcePath
                      toPath:(NSString *)destinationPath
                shouldCancel:(NS_NOESCAPE BOOL (^)(void))shouldCancel
                       error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(decompressFile(atPath:toPath:shouldCancel:));

@end

NS_ASSUME_NONNULL_END
