/*
 Copyright (c) 2012-2019, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <os/object.h>
#import <sys/socket.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#import <dns_sd.h>

/**
 *  All GCDWebServer headers.
 */

#import "GCDWebServerHTTPStatusCodes.h"
#import "GCDWebServerFunctions.h"

#import "GCDWebServer.h"
#import "GCDWebServerConnection.h"

#import "GCDWebServerDataRequest.h"
#import "GCDWebServerFileRequest.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerURLEncodedFormRequest.h"

#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerStreamedResponse.h"

/**
 *  Check if a custom logging facility should be used instead.
 */

#if defined(__GCDWEBSERVER_LOGGING_HEADER__)

#define __GCDWEBSERVER_LOGGING_FACILITY_CUSTOM__

#import __GCDWEBSERVER_LOGGING_HEADER__

/**
 *  Automatically detect if XLFacility is available and if so use it as a
 *  logging facility.
 */

#elif defined(__has_include) && __has_include("XLFacilityMacros.h")

#define __GCDWEBSERVER_LOGGING_FACILITY_XLFACILITY__

#undef XLOG_TAG
#define XLOG_TAG @"gcdwebserver.internal"

#import "XLFacilityMacros.h"

#define GWS_LOG_DEBUG(...) XLOG_DEBUG(__VA_ARGS__)
#define GWS_LOG_VERBOSE(...) XLOG_VERBOSE(__VA_ARGS__)
#define GWS_LOG_INFO(...) XLOG_INFO(__VA_ARGS__)
#define GWS_LOG_WARNING(...) XLOG_WARNING(__VA_ARGS__)
#define GWS_LOG_ERROR(...) XLOG_ERROR(__VA_ARGS__)

#define GWS_DCHECK(__CONDITION__) XLOG_DEBUG_CHECK(__CONDITION__)
#define GWS_DNOT_REACHED() XLOG_DEBUG_UNREACHABLE()

/**
 *  If all of the above fail, then use GCDWebServer built-in
 *  logging facility.
 */

#else

#define __GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__

typedef NS_ENUM(int, GCDWebServerLoggingLevel) {
  kGCDWebServerLoggingLevel_Debug = 0,
  kGCDWebServerLoggingLevel_Verbose,
  kGCDWebServerLoggingLevel_Info,
  kGCDWebServerLoggingLevel_Warning,
  kGCDWebServerLoggingLevel_Error
};

extern GCDWebServerLoggingLevel GCDWebServerLogLevel;
extern void GCDWebServerLogMessage(GCDWebServerLoggingLevel level, NSString* _Nonnull format, ...) NS_FORMAT_FUNCTION(2, 3);

#if DEBUG
#define GWS_LOG_DEBUG(...)                                                                                                             \
  do {                                                                                                                                 \
    if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Debug) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Debug, __VA_ARGS__); \
  } while (0)
#else
#define GWS_LOG_DEBUG(...)
#endif
#define GWS_LOG_VERBOSE(...)                                                                                                               \
  do {                                                                                                                                     \
    if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Verbose) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Verbose, __VA_ARGS__); \
  } while (0)
#define GWS_LOG_INFO(...)                                                                                                            \
  do {                                                                                                                               \
    if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Info) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Info, __VA_ARGS__); \
  } while (0)
#define GWS_LOG_WARNING(...)                                                                                                               \
  do {                                                                                                                                     \
    if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Warning) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Warning, __VA_ARGS__); \
  } while (0)
#define GWS_LOG_ERROR(...)                                                                                                             \
  do {                                                                                                                                 \
    if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Error) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Error, __VA_ARGS__); \
  } while (0)

#endif

/**
 *  Consistency check macros used when building Debug only.
 */

#if !defined(GWS_DCHECK) || !defined(GWS_DNOT_REACHED)

#if DEBUG

#define GWS_DCHECK(__CONDITION__) \
  do {                            \
    if (!(__CONDITION__)) {       \
      abort();                    \
    }                             \
  } while (0)
#define GWS_DNOT_REACHED() abort()

#else

#define GWS_DCHECK(__CONDITION__)
#define GWS_DNOT_REACHED()

#endif

#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  GCDWebServer internal constants and APIs.
 */

#define kGCDWebServerDefaultMimeType @"application/octet-stream"
#define kGCDWebServerErrorDomain @"GCDWebServerErrorDomain"

static inline BOOL GCDWebServerIsValidByteRange(NSRange range) {
  return ((range.location != NSUIntegerMax) || (range.length > 0));
}

static inline NSError* GCDWebServerMakePosixError(int code) {
  return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : (NSString*)[NSString stringWithUTF8String:strerror(code)]}];
}

extern void GCDWebServerInitializeFunctions(void);
extern NSString* GCDWebServerEnsureUTF8CharsetIfNeeded(NSString* mimeType);
extern NSString* _Nullable GCDWebServerNormalizeHeaderValue(NSString* _Nullable value);
extern NSString* _Nullable GCDWebServerTruncateHeaderValue(NSString* _Nullable value);
extern NSString* _Nullable GCDWebServerExtractHeaderValueParameter(NSString* _Nullable value, NSString* attribute);
extern NSStringEncoding GCDWebServerStringEncodingFromCharset(NSString* charset);
extern BOOL GCDWebServerIsTextContentType(NSString* type);
extern NSString* GCDWebServerDescribeData(NSData* data, NSString* contentType);
extern NSString* GCDWebServerComputeMD5Digest(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
extern NSString* GCDWebServerStringFromSockAddr(const struct sockaddr* addr, BOOL includeService);

@interface GCDWebServerConnection ()
- (instancetype)initWithServer:(GCDWebServer*)server localAddress:(NSData*)localAddress remoteAddress:(NSData*)remoteAddress socket:(CFSocketNativeHandle)socket;
/// GCD-3: Abort pending async processing and shut down the socket (server stop).
- (void)abortForServerStop;
@end


// GCD-23: Ivars live in the private class extension so multi-file categories can access them.
@interface GCDWebServer () {
  // Public / synthesized properties
  __weak id<GCDWebServerDelegate> _delegate;
  NSUInteger _port;
  NSString* _serverName;
  BOOL _shouldAutomaticallyMapHEADToGET;
  dispatch_queue_priority_t _dispatchQueuePriority;

  // Runtime state
  dispatch_queue_t _syncQueue;
  dispatch_queue_t _lifecycleQueue;  // GCD-4: serial queue for stop / auto-suspend (never block main)
  dispatch_group_t _sourceGroup;
  NSMutableArray<GCDWebServerHandler*>* _handlers;
  // GCD-28: O(1) exact path + ordered prefix maps (checked before LIFO matchBlocks).
  NSMutableDictionary<NSString*, GCDWebServerHandler*>* _exactHandlers;  // key: "METHOD path" (path lowercased)
  NSMutableArray<NSDictionary*>* _prefixHandlers;  // LIFO among prefixes: @{@"method", @"prefix", @"handler"}
  NSInteger _activeConnections;  // Accessed through _syncQueue only
  NSHashTable<GCDWebServerConnection*>* _activeConnectionSet;  // Weak; accessed through _syncQueue only (GCD-3)
  BOOL _connected;  // Accessed on main thread only
  dispatch_block_t _disconnectBlock;  // Accessed on main thread only

  NSDictionary<NSString*, id>* _options;
  NSMutableDictionary<NSString*, NSString*>* _authenticationBasicAccounts;
  NSMutableDictionary<NSString*, NSString*>* _authenticationDigestAccounts;
  NSString* _authenticationRealm;
  Class _connectionClass;
  CFTimeInterval _disconnectDelay;
  dispatch_source_t _source4;
  dispatch_source_t _source6;
  CFNetServiceRef _registrationService;
  CFNetServiceRef _resolutionService;
  DNSServiceRef _dnsService;
  CFSocketRef _dnsSocket;
  CFRunLoopSourceRef _dnsSource;
  NSString* _dnsAddress;
  NSUInteger _dnsPort;
  BOOL _bindToLocalhost;
  BOOL _enableKeepAlive;  // GCD-7
  NSUInteger _maxKeepAliveRequests;  // GCD-7
  NSTimeInterval _keepAliveIdleTimeout;  // GCD-29
#if TARGET_OS_IPHONE
  BOOL _suspendInBackground;
  UIBackgroundTaskIdentifier _backgroundTask;
#endif
#ifdef __GCDWEBSERVER_ENABLE_TESTING__
  BOOL _recording;
#endif
}

@property(nonatomic, readonly) NSMutableArray<GCDWebServerHandler*>* handlers;
/**
 *  GCD-28: Resolve a handler. Precedence: exact path map → prefix map (LIFO) → legacy LIFO matchBlocks.
 *  On success, outHandler and outRequest are set.
 */
- (BOOL)matchHandlerForMethod:(NSString*)method
                          url:(NSURL*)url
                      headers:(NSDictionary<NSString*, NSString*>*)headers
                         path:(NSString*)path
                        query:(NSDictionary<NSString*, NSString*>*)query
                      handler:(GCDWebServerHandler* _Nullable* _Nonnull)outHandler
                      request:(GCDWebServerRequest* _Nullable* _Nonnull)outRequest;
@property(nonatomic, readonly, nullable) NSString* serverName;
@property(nonatomic, readonly, nullable) NSString* authenticationRealm;
@property(nonatomic, readonly, nullable) NSMutableDictionary<NSString*, NSString*>* authenticationBasicAccounts;
@property(nonatomic, readonly, nullable) NSMutableDictionary<NSString*, NSString*>* authenticationDigestAccounts;
@property(nonatomic, readonly) BOOL shouldAutomaticallyMapHEADToGET;
@property(nonatomic, readonly) dispatch_queue_priority_t dispatchQueuePriority;
@property(nonatomic, readonly) BOOL enableKeepAlive;  // GCD-7
@property(nonatomic, readonly) NSUInteger maxKeepAliveRequests;  // GCD-7
@property(nonatomic, readonly) NSTimeInterval keepAliveIdleTimeout;  // GCD-29
- (void)willStartConnection:(GCDWebServerConnection*)connection;
- (void)didEndConnection:(GCDWebServerConnection*)connection;
@end

@interface GCDWebServerHandler : NSObject
@property(nonatomic, readonly) GCDWebServerMatchBlock matchBlock;
@property(nonatomic, readonly) GCDWebServerAsyncProcessBlock asyncProcessBlock;
- (instancetype)initWithMatchBlock:(GCDWebServerMatchBlock)matchBlock asyncProcessBlock:(GCDWebServerAsyncProcessBlock)processBlock;
@end

@interface GCDWebServer (ExactPrefixRouterInternal)
- (void)addExactHandlerForMethod:(NSString*)method path:(NSString*)path handler:(GCDWebServerHandler*)handler;
- (void)addPrefixHandlerForMethod:(NSString*)method pathPrefix:(NSString*)prefix handler:(GCDWebServerHandler*)handler;
@end

@interface GCDWebServerRequest ()
@property(nonatomic, readonly) BOOL usesChunkedTransferEncoding;
@property(nonatomic) NSData* localAddressData;
@property(nonatomic) NSData* remoteAddressData;
- (void)prepareForWriting;
- (BOOL)performOpen:(NSError**)error;
- (BOOL)performWriteData:(NSData*)data error:(NSError**)error;
- (BOOL)performClose:(NSError**)error;
- (void)setAttribute:(nullable id)attribute forKey:(NSString*)key;
@end

@interface GCDWebServerResponse ()
@property(nonatomic, readonly) NSDictionary<NSString*, NSString*>* additionalHeaders;
@property(nonatomic, readonly) BOOL usesChunkedTransferEncoding;
- (void)prepareForReading;
- (BOOL)performOpen:(NSError**)error;
- (void)performReadDataWithCompletion:(GCDWebServerBodyReaderCompletionBlock)block;
- (void)performClose;
@end

NS_ASSUME_NONNULL_END
