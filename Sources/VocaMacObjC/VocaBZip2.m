// VocaBZip2.m
// VocaMac
//
// bzip2 decompression with the system libbz2, so model archives can be
// unpacked without starting /usr/bin/tar.

#import "VocaMacObjC.h"

#import <bzlib.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static NSString * const VocaBZip2ErrorDomain = @"com.vocamac.bzip2";
static const unsigned int VocaBZip2BufferSize = 1 << 16;

static NSError *VocaBZip2Error(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:VocaBZip2ErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@implementation VocaBZip2

+ (BOOL)decompressFileAtPath:(NSString *)sourcePath
                      toPath:(NSString *)destinationPath
                shouldCancel:(NS_NOESCAPE BOOL (^)(void))shouldCancel
                       error:(NSError * _Nullable * _Nullable)error {
    FILE *input = fopen(sourcePath.fileSystemRepresentation, "rb");
    if (input == NULL) {
        if (error) { *error = VocaBZip2Error(1, @"The archive couldn't be opened."); }
        return NO;
    }
    FILE *output = fopen(destinationPath.fileSystemRepresentation, "wb");
    if (output == NULL) {
        fclose(input);
        if (error) { *error = VocaBZip2Error(2, @"The unpacked archive couldn't be written."); }
        return NO;
    }

    char *inBuffer = malloc(VocaBZip2BufferSize);
    char *outBuffer = malloc(VocaBZip2BufferSize);
    bz_stream stream;
    memset(&stream, 0, sizeof(stream));
    // A file can hold several bzip2 streams back to back (pbzip2 writes them
    // that way); each one is decompressed in turn.
    BOOL inStream = NO;
    BOOL finishedAStream = NO;
    // A full output buffer may leave more output inside libbz2, so no more
    // input is read until a call returns with room to spare.
    BOOL outputFull = NO;
    NSError *failure = nil;

    if (inBuffer == NULL || outBuffer == NULL) {
        failure = VocaBZip2Error(3, @"Not enough memory to unpack the archive.");
    }

    while (failure == nil) {
        if (shouldCancel()) {
            failure = VocaBZip2Error(4, @"Unpacking was cancelled.");
            break;
        }
        if (stream.avail_in == 0 && !outputFull) {
            size_t count = fread(inBuffer, 1, VocaBZip2BufferSize, input);
            if (count == 0) {
                if (ferror(input)) {
                    failure = VocaBZip2Error(1, @"The archive couldn't be read.");
                } else if (inStream || !finishedAStream) {
                    failure = VocaBZip2Error(5, @"The archive is incomplete.");
                }
                break;
            }
            stream.next_in = inBuffer;
            stream.avail_in = (unsigned int)count;
        }
        if (!inStream) {
            char *nextIn = stream.next_in;
            unsigned int availableIn = stream.avail_in;
            memset(&stream, 0, sizeof(stream));
            if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK) {
                failure = VocaBZip2Error(3, @"The archive couldn't be unpacked.");
                break;
            }
            stream.next_in = nextIn;
            stream.avail_in = availableIn;
            inStream = YES;
        }

        stream.next_out = outBuffer;
        stream.avail_out = VocaBZip2BufferSize;
        int status = BZ2_bzDecompress(&stream);
        size_t produced = (size_t)(VocaBZip2BufferSize - stream.avail_out);
        outputFull = stream.avail_out == 0;
        if (produced > 0 && fwrite(outBuffer, 1, produced, output) != produced) {
            failure = VocaBZip2Error(2, @"The unpacked archive couldn't be written.");
            break;
        }

        if (status == BZ_STREAM_END) {
            BZ2_bzDecompressEnd(&stream);
            inStream = NO;
            finishedAStream = YES;
            outputFull = NO;
        } else if (status == BZ_DATA_ERROR_MAGIC && finishedAStream) {
            // Padding after the last stream, which bzip2(1) ignores too.
            BZ2_bzDecompressEnd(&stream);
            inStream = NO;
            break;
        } else if (status != BZ_OK) {
            failure = VocaBZip2Error(6, @"The archive is damaged.");
            break;
        }
    }

    if (inStream) {
        BZ2_bzDecompressEnd(&stream);
    }
    free(inBuffer);
    free(outBuffer);
    fclose(input);
    if (fclose(output) != 0 && failure == nil) {
        failure = VocaBZip2Error(2, @"The unpacked archive couldn't be written.");
    }

    if (failure != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
        if (error) { *error = failure; }
        return NO;
    }
    return YES;
}

@end
