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

#if !__has_feature(objc_arc)
#error GCDWebServer requires ARC
#endif

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#import <netinet/in.h>
#import <dns_sd.h>

#import "GCDWebServerPrivate.h"

#if TARGET_IPHONE_SIMULATOR
#define kDefaultPort 8080
#else
#define kDefaultPort 80
#endif


#if TARGET_OS_IPHONE
// Returns YES when running inside an app extension process.
// UIApplication.sharedApplication is unavailable in extensions and returns nil,
// so any code that calls it must be skipped in that context.
static BOOL _GCDWebServerIsAppExtension(void) {
  static BOOL isExtension;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    isExtension = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSExtension"] != nil;
  });
  return isExtension;
}
#endif

NSString* const GCDWebServerOption_Port = @"Port";
NSString* const GCDWebServerOption_BonjourName = @"BonjourName";
NSString* const GCDWebServerOption_BonjourType = @"BonjourType";
NSString* const GCDWebServerOption_BonjourTXTData = @"BonjourTXTData";
NSString* const GCDWebServerOption_RequestNATPortMapping = @"RequestNATPortMapping";
NSString* const GCDWebServerOption_BindToLocalhost = @"BindToLocalhost";
NSString* const GCDWebServerOption_MaxPendingConnections = @"MaxPendingConnections";
NSString* const GCDWebServerOption_ServerName = @"ServerName";
NSString* const GCDWebServerOption_AuthenticationMethod = @"AuthenticationMethod";
NSString* const GCDWebServerOption_AuthenticationRealm = @"AuthenticationRealm";
NSString* const GCDWebServerOption_AuthenticationAccounts = @"AuthenticationAccounts";
NSString* const GCDWebServerOption_ConnectionClass = @"ConnectionClass";
NSString* const GCDWebServerOption_AutomaticallyMapHEADToGET = @"AutomaticallyMapHEADToGET";
NSString* const GCDWebServerOption_ConnectedStateCoalescingInterval = @"ConnectedStateCoalescingInterval";
NSString* const GCDWebServerOption_DispatchQueuePriority = @"DispatchQueuePriority";
NSString* const GCDWebServerOption_AutomaticallySuspendInBackground = @"AutomaticallySuspendInBackground";
NSString* const GCDWebServerOption_EnableKeepAlive = @"EnableKeepAlive";
NSString* const GCDWebServerOption_MaxKeepAliveRequests = @"MaxKeepAliveRequests";
NSString* const GCDWebServerOption_KeepAliveIdleTimeout = @"KeepAliveIdleTimeout";
NSString* const GCDWebServerOption_MaxRequestBodyLength = @"MaxRequestBodyLength";

NSString* const GCDWebServerAuthenticationMethod_Basic = @"Basic";
NSString* const GCDWebServerAuthenticationMethod_DigestAccess = @"DigestAccess";

// GCD-23: built-in logging lives in GCDWebServer+Logging.m; testing harness in GCDWebServer+Testing.m

@implementation GCDWebServerHandler

- (instancetype)initWithMatchBlock:(GCDWebServerMatchBlock _Nonnull)matchBlock asyncProcessBlock:(GCDWebServerAsyncProcessBlock _Nonnull)processBlock {
  if ((self = [super init])) {
    _matchBlock = [matchBlock copy];
    _asyncProcessBlock = [processBlock copy];
  }
  return self;
}

@end

@implementation GCDWebServer
// GCD-23: ivars declared in GCDWebServerPrivate.h class extension

// Expose keep-alive options to connections (GCD-7).
- (BOOL)enableKeepAlive {
  return _enableKeepAlive;
}

- (NSUInteger)maxKeepAliveRequests {
  return _maxKeepAliveRequests;
}

- (NSTimeInterval)keepAliveIdleTimeout {
  return _keepAliveIdleTimeout;
}

- (NSUInteger)maxRequestBodyLength {
  return _maxRequestBodyLength;
}

+ (void)initialize {
  GCDWebServerInitializeFunctions();
}

- (instancetype)init {
  if ((self = [super init])) {
    _syncQueue = dispatch_queue_create([NSStringFromClass([self class]) UTF8String], DISPATCH_QUEUE_SERIAL);
    _lifecycleQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@.lifecycle", NSStringFromClass([self class])] UTF8String], DISPATCH_QUEUE_SERIAL);
    _sourceGroup = dispatch_group_create();
    _handlers = [[NSMutableArray alloc] init];
    _exactHandlers = [[NSMutableDictionary alloc] init];
    _prefixHandlers = [[NSMutableArray alloc] init];
    _activeConnectionSet = [NSHashTable weakObjectsHashTable];
#if TARGET_OS_IPHONE
    _backgroundTask = UIBackgroundTaskInvalid;
#endif
  }
  return self;
}

- (void)dealloc {
  GWS_DCHECK(_connected == NO);
  GWS_DCHECK(_activeConnections == 0);
  GWS_DCHECK(_options == nil);  // The server can never be dealloc'ed while running because of the retain-cycle with the dispatch source
  GWS_DCHECK(_disconnectBlock == NULL);  // The server can never be dealloc'ed while the disconnect block is pending because of the retain-cycle

#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
  dispatch_release(_sourceGroup);
  dispatch_release(_lifecycleQueue);
  dispatch_release(_syncQueue);
#endif
}

#if TARGET_OS_IPHONE

// Always called on main thread
- (void)_startBackgroundTask {
  GWS_DCHECK([NSThread isMainThread]);
  if (_backgroundTask == UIBackgroundTaskInvalid) {
    GWS_LOG_DEBUG(@"Did start background task");
    if (!_GCDWebServerIsAppExtension()) {
      _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        GWS_LOG_WARNING(@"Application is being suspended while %@ is still connected", [self class]);
        [self _endBackgroundTask];
      }];
    }
  } else {
    GWS_DNOT_REACHED();
  }
}

#endif

// Always called on main thread
- (void)_didConnect {
  GWS_DCHECK([NSThread isMainThread]);
  GWS_DCHECK(_connected == NO);
  _connected = YES;
  GWS_LOG_DEBUG(@"Did connect");

#if TARGET_OS_IPHONE
  if (!_GCDWebServerIsAppExtension() && [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground) {
    [self _startBackgroundTask];
  }
#endif

  if ([_delegate respondsToSelector:@selector(webServerDidConnect:)]) {
    [_delegate webServerDidConnect:self];
  }
}

- (void)willStartConnection:(GCDWebServerConnection*)connection {
  dispatch_sync(_syncQueue, ^{
    GWS_DCHECK(self->_activeConnections >= 0);
    if (self->_activeConnections == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_disconnectBlock) {
          dispatch_block_cancel(self->_disconnectBlock);
          self->_disconnectBlock = NULL;
        }
        if (self->_connected == NO) {
          [self _didConnect];
        }
      });
    }
    self->_activeConnections += 1;
    [self->_activeConnectionSet addObject:connection];
  });
}

#if TARGET_OS_IPHONE

// Always called on main thread
- (void)_endBackgroundTask {
  GWS_DCHECK([NSThread isMainThread]);
  if (_backgroundTask != UIBackgroundTaskInvalid) {
    UIBackgroundTaskIdentifier task = _backgroundTask;
    _backgroundTask = UIBackgroundTaskInvalid;
    if (!_GCDWebServerIsAppExtension()) {
      // GCD-4: never run blocking _stop on the main thread (priority inversion).
      BOOL shouldStop = _suspendInBackground && ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) && (_source4 != NULL);
      if (shouldStop) {
        dispatch_async(_lifecycleQueue, ^{
          if (self->_source4) {
            [self _stop];
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] endBackgroundTask:task];
            GWS_LOG_DEBUG(@"Did end background task");
          });
        });
        return;
      }
      [[UIApplication sharedApplication] endBackgroundTask:task];
    }
    GWS_LOG_DEBUG(@"Did end background task");
  }
}

#endif

// Always called on main thread
- (void)_didDisconnect {
  GWS_DCHECK([NSThread isMainThread]);
  GWS_DCHECK(_connected == YES);
  _connected = NO;
  GWS_LOG_DEBUG(@"Did disconnect");

#if TARGET_OS_IPHONE
  [self _endBackgroundTask];
#endif

  if ([_delegate respondsToSelector:@selector(webServerDidDisconnect:)]) {
    [_delegate webServerDidDisconnect:self];
  }
}

- (void)didEndConnection:(GCDWebServerConnection*)connection {
  dispatch_sync(_syncQueue, ^{
    GWS_DCHECK(self->_activeConnections > 0);
    self->_activeConnections -= 1;
    [self->_activeConnectionSet removeObject:connection];
    if (self->_activeConnections == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if ((self->_disconnectDelay > 0.0) && (self->_source4 != NULL)) {
          if (self->_disconnectBlock) {
            dispatch_block_cancel(self->_disconnectBlock);
          }
          dispatch_block_t block = dispatch_block_create(0, ^{
            GWS_DCHECK([NSThread isMainThread]);
            self->_disconnectBlock = NULL;
            [self _didDisconnect];
          });
          self->_disconnectBlock = block;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self->_disconnectDelay * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), block);
        } else {
          [self _didDisconnect];
        }
      });
    }
  });
}

- (NSString*)bonjourName {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CFStringRef name = _resolutionService ? CFNetServiceGetName(_resolutionService) : NULL;
#pragma clang diagnostic pop
  return name && CFStringGetLength(name) ? CFBridgingRelease(CFStringCreateCopy(kCFAllocatorDefault, name)) : nil;
}

- (NSString*)bonjourType {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CFStringRef type = _resolutionService ? CFNetServiceGetType(_resolutionService) : NULL;
#pragma clang diagnostic pop
  return type && CFStringGetLength(type) ? CFBridgingRelease(CFStringCreateCopy(kCFAllocatorDefault, type)) : nil;
}

- (void)addHandlerWithMatchBlock:(GCDWebServerMatchBlock)matchBlock processBlock:(GCDWebServerProcessBlock)processBlock {
  [self addHandlerWithMatchBlock:matchBlock
               asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
                 completionBlock(processBlock(request));
               }];
}

- (void)addHandlerWithMatchBlock:(GCDWebServerMatchBlock)matchBlock asyncProcessBlock:(GCDWebServerAsyncProcessBlock)processBlock {
  GWS_DCHECK(_options == nil);
  GCDWebServerHandler* handler = [[GCDWebServerHandler alloc] initWithMatchBlock:matchBlock asyncProcessBlock:processBlock];
  [_handlers insertObject:handler atIndex:0];
}

- (void)removeAllHandlers {
  GWS_DCHECK(_options == nil);
  [_handlers removeAllObjects];
  [_exactHandlers removeAllObjects];
  [_prefixHandlers removeAllObjects];
}

// GCD-28: exact → prefix (LIFO) → legacy matchBlock list (LIFO).
- (BOOL)matchHandlerForMethod:(NSString*)method
                          url:(NSURL*)url
                      headers:(NSDictionary<NSString*, NSString*>*)headers
                         path:(NSString*)path
                        query:(NSDictionary<NSString*, NSString*>*)query
                      handler:(GCDWebServerHandler* _Nullable* _Nonnull)outHandler
                      request:(GCDWebServerRequest* _Nullable* _Nonnull)outRequest {
  NSString* exactKey = [NSString stringWithFormat:@"%@ %@", method, path.lowercaseString];
  GCDWebServerHandler* candidate = _exactHandlers[exactKey];
  if (candidate) {
    GCDWebServerRequest* req = candidate.matchBlock(method, url, headers, path, query);
    if (req) {
      *outHandler = candidate;
      *outRequest = req;
      return YES;
    }
  }

  for (NSDictionary* entry in _prefixHandlers) {
    if (![entry[@"method"] isEqualToString:method]) {
      continue;
    }
    NSString* prefix = entry[@"prefix"];
    if ([path hasPrefix:prefix] || [path.lowercaseString hasPrefix:((NSString*)prefix).lowercaseString]) {
      candidate = entry[@"handler"];
      GCDWebServerRequest* req = candidate.matchBlock(method, url, headers, path, query);
      if (req) {
        *outHandler = candidate;
        *outRequest = req;
        return YES;
      }
    }
  }

  for (GCDWebServerHandler* handler in _handlers) {
    GCDWebServerRequest* req = handler.matchBlock(method, url, headers, path, query);
    if (req) {
      *outHandler = handler;
      *outRequest = req;
      return YES;
    }
  }
  return NO;
}

- (void)addExactHandlerForMethod:(NSString*)method path:(NSString*)path handler:(GCDWebServerHandler*)handler {
  GWS_DCHECK(_options == nil);
  NSString* key = [NSString stringWithFormat:@"%@ %@", method, path.lowercaseString];
  _exactHandlers[key] = handler;
}

- (void)addPrefixHandlerForMethod:(NSString*)method pathPrefix:(NSString*)prefix handler:(GCDWebServerHandler*)handler {
  GWS_DCHECK(_options == nil);
  // LIFO among prefixes: newest first.
  [_prefixHandlers insertObject:@{@"method" : method, @"prefix" : prefix, @"handler" : handler} atIndex:0];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void _NetServiceRegisterCallBack(CFNetServiceRef service, CFStreamError* error, void* info) {
  GWS_DCHECK([NSThread isMainThread]);
  @autoreleasepool {
    if (error->error) {
      GWS_LOG_ERROR(@"Bonjour registration error %i (domain %i)", (int)error->error, (int)error->domain);
    } else {
      GCDWebServer* server = (__bridge GCDWebServer*)info;
      GWS_LOG_VERBOSE(@"Bonjour registration complete for %@", [server class]);
      if (!CFNetServiceResolveWithTimeout(server->_resolutionService, 5.0, NULL)) {
        GWS_LOG_ERROR(@"Failed starting Bonjour resolution");
        GWS_DNOT_REACHED();
      }
    }
  }
}

static void _NetServiceResolveCallBack(CFNetServiceRef service, CFStreamError* error, void* info) {
  GWS_DCHECK([NSThread isMainThread]);
  @autoreleasepool {
    if (error->error) {
      if ((error->domain != kCFStreamErrorDomainNetServices) && (error->error != kCFNetServicesErrorTimeout)) {
        GWS_LOG_ERROR(@"Bonjour resolution error %i (domain %i)", (int)error->error, (int)error->domain);
      }
    } else {
      GCDWebServer* server = (__bridge GCDWebServer*)info;
      GWS_LOG_INFO(@"%@ now locally reachable at %@", [server class], server.bonjourServerURL);
      if ([server.delegate respondsToSelector:@selector(webServerDidCompleteBonjourRegistration:)]) {
        [server.delegate webServerDidCompleteBonjourRegistration:server];
      }
    }
  }
}

#pragma clang diagnostic pop

static void _DNSServiceCallBack(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, uint32_t externalAddress, DNSServiceProtocol protocol, uint16_t internalPort, uint16_t externalPort, uint32_t ttl, void* context) {
  GWS_DCHECK([NSThread isMainThread]);
  @autoreleasepool {
    GCDWebServer* server = (__bridge GCDWebServer*)context;
    if ((errorCode == kDNSServiceErr_NoError) || (errorCode == kDNSServiceErr_DoubleNAT)) {
      struct sockaddr_in addr4;
      bzero(&addr4, sizeof(addr4));
      addr4.sin_len = sizeof(addr4);
      addr4.sin_family = AF_INET;
      addr4.sin_addr.s_addr = externalAddress;  // Already in network byte order
      server->_dnsAddress = GCDWebServerStringFromSockAddr((const struct sockaddr*)&addr4, NO);
      server->_dnsPort = ntohs(externalPort);
      GWS_LOG_INFO(@"%@ now publicly reachable at %@", [server class], server.publicServerURL);
    } else {
      GWS_LOG_ERROR(@"DNS service error %i", errorCode);
      server->_dnsAddress = nil;
      server->_dnsPort = 0;
    }
    if ([server.delegate respondsToSelector:@selector(webServerDidUpdateNATPortMapping:)]) {
      [server.delegate webServerDidUpdateNATPortMapping:server];
    }
  }
}

static void _SocketCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void* data, void* info) {
  GWS_DCHECK([NSThread isMainThread]);
  @autoreleasepool {
    GCDWebServer* server = (__bridge GCDWebServer*)info;
    DNSServiceErrorType status = DNSServiceProcessResult(server->_dnsService);
    if (status != kDNSServiceErr_NoError) {
      GWS_LOG_ERROR(@"DNS service error %i", status);
    }
  }
}

static inline id _GetOption(NSDictionary<NSString*, id>* options, NSString* key, id defaultValue) {
  id value = [options objectForKey:key];
  return value ? value : defaultValue;
}

static inline NSString* _EncodeBase64(NSString* string) {
  NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
  return [[NSString alloc] initWithData:[data base64EncodedDataWithOptions:0] encoding:NSASCIIStringEncoding];
}

- (int)_createListeningSocket:(BOOL)useIPv6
                 localAddress:(const void*)address
                       length:(socklen_t)length
        maxPendingConnections:(NSUInteger)maxPendingConnections
                        error:(NSError**)error {
  int listeningSocket = socket(useIPv6 ? PF_INET6 : PF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listeningSocket > 0) {
    int yes = 1;
    setsockopt(listeningSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    if (bind(listeningSocket, address, length) == 0) {
      if (listen(listeningSocket, (int)maxPendingConnections) == 0) {
        GWS_LOG_DEBUG(@"Did open %s listening socket %i", useIPv6 ? "IPv6" : "IPv4", listeningSocket);
        return listeningSocket;
      } else {
        if (error) {
          *error = GCDWebServerMakePosixError(errno);
        }
        GWS_LOG_ERROR(@"Failed starting %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
        close(listeningSocket);
      }
    } else {
      if (error) {
        *error = GCDWebServerMakePosixError(errno);
      }
      GWS_LOG_ERROR(@"Failed binding %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
      close(listeningSocket);
    }

  } else {
    if (error) {
      *error = GCDWebServerMakePosixError(errno);
    }
    GWS_LOG_ERROR(@"Failed creating %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
  }
  return -1;
}

- (dispatch_source_t)_createDispatchSourceWithListeningSocket:(int)listeningSocket isIPv6:(BOOL)isIPv6 {
  dispatch_group_enter(_sourceGroup);
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listeningSocket, 0, dispatch_get_global_queue(_dispatchQueuePriority, 0));
  dispatch_source_set_cancel_handler(source, ^{
    @autoreleasepool {
      int result = close(listeningSocket);
      if (result != 0) {
        GWS_LOG_ERROR(@"Failed closing %s listening socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
      } else {
        GWS_LOG_DEBUG(@"Did close %s listening socket %i", isIPv6 ? "IPv6" : "IPv4", listeningSocket);
      }
    }
    dispatch_group_leave(self->_sourceGroup);
  });
  dispatch_source_set_event_handler(source, ^{
    @autoreleasepool {
      struct sockaddr_storage remoteSockAddr;
      socklen_t remoteAddrLen = sizeof(remoteSockAddr);
      int socket = accept(listeningSocket, (struct sockaddr*)&remoteSockAddr, &remoteAddrLen);
      if (socket > 0) {
        NSData* remoteAddress = [NSData dataWithBytes:&remoteSockAddr length:remoteAddrLen];

        struct sockaddr_storage localSockAddr;
        socklen_t localAddrLen = sizeof(localSockAddr);
        NSData* localAddress = nil;
        if (getsockname(socket, (struct sockaddr*)&localSockAddr, &localAddrLen) == 0) {
          localAddress = [NSData dataWithBytes:&localSockAddr length:localAddrLen];
          GWS_DCHECK((!isIPv6 && localSockAddr.ss_family == AF_INET) || (isIPv6 && localSockAddr.ss_family == AF_INET6));
        } else {
          GWS_DNOT_REACHED();
        }

        int noSigPipe = 1;
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));  // Make sure this socket cannot generate SIG_PIPE

        GCDWebServerConnection* connection = [(GCDWebServerConnection*)[self->_connectionClass alloc] initWithServer:self localAddress:localAddress remoteAddress:remoteAddress socket:socket];  // Connection will automatically retain itself while opened
        [connection self];  // Prevent compiler from complaining about unused variable / useless statement
      } else {
        GWS_LOG_ERROR(@"Failed accepting %s socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
      }
    }
  });
  return source;
}

- (BOOL)_start:(NSError**)error {
  GWS_DCHECK(_source4 == NULL);

  NSUInteger port = [(NSNumber*)_GetOption(_options, GCDWebServerOption_Port, @0) unsignedIntegerValue];
  BOOL bindToLocalhost = [(NSNumber*)_GetOption(_options, GCDWebServerOption_BindToLocalhost, @NO) boolValue];
  NSUInteger maxPendingConnections = [(NSNumber*)_GetOption(_options, GCDWebServerOption_MaxPendingConnections, @16) unsignedIntegerValue];

  struct sockaddr_in addr4;
  bzero(&addr4, sizeof(addr4));
  addr4.sin_len = sizeof(addr4);
  addr4.sin_family = AF_INET;
  addr4.sin_port = htons(port);
  addr4.sin_addr.s_addr = bindToLocalhost ? htonl(INADDR_LOOPBACK) : htonl(INADDR_ANY);
  int listeningSocket4 = [self _createListeningSocket:NO localAddress:&addr4 length:sizeof(addr4) maxPendingConnections:maxPendingConnections error:error];
  if (listeningSocket4 <= 0) {
    return NO;
  }
  if (port == 0) {
    struct sockaddr_in addr;
    socklen_t addrlen = sizeof(addr);
    if (getsockname(listeningSocket4, (struct sockaddr*)&addr, &addrlen) == 0) {
      port = ntohs(addr.sin_port);
    } else {
      GWS_LOG_ERROR(@"Failed retrieving socket address: %s (%i)", strerror(errno), errno);
    }
  }

  struct sockaddr_in6 addr6;
  bzero(&addr6, sizeof(addr6));
  addr6.sin6_len = sizeof(addr6);
  addr6.sin6_family = AF_INET6;
  addr6.sin6_port = htons(port);
  addr6.sin6_addr = bindToLocalhost ? in6addr_loopback : in6addr_any;
  int listeningSocket6 = [self _createListeningSocket:YES localAddress:&addr6 length:sizeof(addr6) maxPendingConnections:maxPendingConnections error:error];
  if (listeningSocket6 <= 0) {
    close(listeningSocket4);
    return NO;
  }

  _serverName = [(NSString*)_GetOption(_options, GCDWebServerOption_ServerName, NSStringFromClass([self class])) copy];
  NSString* authenticationMethod = _GetOption(_options, GCDWebServerOption_AuthenticationMethod, nil);
  if ([authenticationMethod isEqualToString:GCDWebServerAuthenticationMethod_Basic]) {
    _authenticationRealm = [(NSString*)_GetOption(_options, GCDWebServerOption_AuthenticationRealm, _serverName) copy];
    _authenticationBasicAccounts = [[NSMutableDictionary alloc] init];
    NSDictionary* accounts = _GetOption(_options, GCDWebServerOption_AuthenticationAccounts, @{});
    [accounts enumerateKeysAndObjectsUsingBlock:^(NSString* username, NSString* password, BOOL* stop) {
      [self->_authenticationBasicAccounts setObject:_EncodeBase64([NSString stringWithFormat:@"%@:%@", username, password]) forKey:username];
    }];
  } else if ([authenticationMethod isEqualToString:GCDWebServerAuthenticationMethod_DigestAccess]) {
    _authenticationRealm = [(NSString*)_GetOption(_options, GCDWebServerOption_AuthenticationRealm, _serverName) copy];
    _authenticationDigestAccounts = [[NSMutableDictionary alloc] init];
    NSDictionary* accounts = _GetOption(_options, GCDWebServerOption_AuthenticationAccounts, @{});
    [accounts enumerateKeysAndObjectsUsingBlock:^(NSString* username, NSString* password, BOOL* stop) {
      [self->_authenticationDigestAccounts setObject:GCDWebServerComputeMD5Digest(@"%@:%@:%@", username, self->_authenticationRealm, password) forKey:username];
    }];
  }
  _connectionClass = _GetOption(_options, GCDWebServerOption_ConnectionClass, [GCDWebServerConnection class]);
  _shouldAutomaticallyMapHEADToGET = [(NSNumber*)_GetOption(_options, GCDWebServerOption_AutomaticallyMapHEADToGET, @YES) boolValue];
  _disconnectDelay = [(NSNumber*)_GetOption(_options, GCDWebServerOption_ConnectedStateCoalescingInterval, @1.0) doubleValue];
  _dispatchQueuePriority = [(NSNumber*)_GetOption(_options, GCDWebServerOption_DispatchQueuePriority, @(DISPATCH_QUEUE_PRIORITY_DEFAULT)) longValue];

  _source4 = [self _createDispatchSourceWithListeningSocket:listeningSocket4 isIPv6:NO];
  _source6 = [self _createDispatchSourceWithListeningSocket:listeningSocket6 isIPv6:YES];
  _port = port;
  _bindToLocalhost = bindToLocalhost;
  // GCD-7
  _enableKeepAlive = [(NSNumber*)_GetOption(_options, GCDWebServerOption_EnableKeepAlive, @NO) boolValue];
  _maxKeepAliveRequests = [(NSNumber*)_GetOption(_options, GCDWebServerOption_MaxKeepAliveRequests, @100) unsignedIntegerValue];
  _keepAliveIdleTimeout = [(NSNumber*)_GetOption(_options, GCDWebServerOption_KeepAliveIdleTimeout, @0) doubleValue];
  _maxRequestBodyLength = [(NSNumber*)_GetOption(_options, GCDWebServerOption_MaxRequestBodyLength, @0) unsignedIntegerValue];
  if (_maxKeepAliveRequests == 0) {
    _maxKeepAliveRequests = 100;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSString* bonjourName = _GetOption(_options, GCDWebServerOption_BonjourName, nil);
  NSString* bonjourType = _GetOption(_options, GCDWebServerOption_BonjourType, @"_http._tcp");
  if (bonjourName) {
    _registrationService = CFNetServiceCreate(kCFAllocatorDefault, CFSTR("local."), (__bridge CFStringRef)bonjourType, (__bridge CFStringRef)(bonjourName.length ? bonjourName : _serverName), (SInt32)_port);
    if (_registrationService) {
      CFNetServiceClientContext context = {0, (__bridge void*)self, NULL, NULL, NULL};

      CFNetServiceSetClient(_registrationService, _NetServiceRegisterCallBack, &context);
      CFNetServiceScheduleWithRunLoop(_registrationService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
      CFStreamError streamError = {0};

      NSDictionary* txtDataDictionary = _GetOption(_options, GCDWebServerOption_BonjourTXTData, nil);
      if (txtDataDictionary != nil) {
        NSUInteger count = txtDataDictionary.count;
        CFStringRef* keys = (CFStringRef*)malloc(count * sizeof(CFStringRef));
        CFStringRef* values = (CFStringRef*)malloc(count * sizeof(CFStringRef));
        NSUInteger index = 0;
        for (NSString *key in txtDataDictionary) {
          NSString *value = txtDataDictionary[key];
          keys[index] = (__bridge CFStringRef)(key);
          values[index] = (__bridge CFStringRef)(value);
          index++;
        }
        CFDictionaryRef txtDictionary = CFDictionaryCreate(CFAllocatorGetDefault(), (void*)keys, (void*)values, count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        free(keys);
        free(values);
        if (txtDictionary != NULL) {
          CFDataRef txtData = CFNetServiceCreateTXTDataWithDictionary(nil, txtDictionary);
          CFRelease(txtDictionary);
          if (txtData != NULL) {
            if (!CFNetServiceSetTXTData(_registrationService, txtData)) {
              GWS_LOG_ERROR(@"Failed setting TXTData");
            }
            CFRelease(txtData);
          }
        }
      }

      CFNetServiceRegisterWithOptions(_registrationService, 0, &streamError);

      _resolutionService = CFNetServiceCreateCopy(kCFAllocatorDefault, _registrationService);
      if (_resolutionService) {
        CFNetServiceSetClient(_resolutionService, _NetServiceResolveCallBack, &context);
        CFNetServiceScheduleWithRunLoop(_resolutionService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
      } else {
        GWS_LOG_ERROR(@"Failed creating CFNetService for resolution");
      }
    } else {
      GWS_LOG_ERROR(@"Failed creating CFNetService for registration");
    }
  }
#pragma clang diagnostic pop

  if ([(NSNumber*)_GetOption(_options, GCDWebServerOption_RequestNATPortMapping, @NO) boolValue]) {
    DNSServiceErrorType status = DNSServiceNATPortMappingCreate(&_dnsService, 0, 0, kDNSServiceProtocol_TCP, htons(port), htons(port), 0, _DNSServiceCallBack, (__bridge void*)self);
    if (status == kDNSServiceErr_NoError) {
      CFSocketContext context = {0, (__bridge void*)self, NULL, NULL, NULL};
      _dnsSocket = CFSocketCreateWithNative(kCFAllocatorDefault, DNSServiceRefSockFD(_dnsService), kCFSocketReadCallBack, _SocketCallBack, &context);
      if (_dnsSocket) {
        CFSocketSetSocketFlags(_dnsSocket, CFSocketGetSocketFlags(_dnsSocket) & ~kCFSocketCloseOnInvalidate);
        _dnsSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _dnsSocket, 0);
        if (_dnsSource) {
          CFRunLoopAddSource(CFRunLoopGetMain(), _dnsSource, kCFRunLoopCommonModes);
        } else {
          GWS_LOG_ERROR(@"Failed creating CFRunLoopSource");
          GWS_DNOT_REACHED();
        }
      } else {
        GWS_LOG_ERROR(@"Failed creating CFSocket");
        GWS_DNOT_REACHED();
      }
    } else {
      GWS_LOG_ERROR(@"Failed creating NAT port mapping (%i)", status);
    }
  }

  dispatch_resume(_source4);
  dispatch_resume(_source6);
  GWS_LOG_INFO(@"%@ started on port %i and reachable at %@", [self class], (int)_port, self.serverURL);
  if ([_delegate respondsToSelector:@selector(webServerDidStart:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_delegate webServerDidStart:self];
    });
  }

  return YES;
}

- (void)_stop {
  GWS_DCHECK(_source4 != NULL);

  // GCD-3: Abort open connections (force async completions + shutdown sockets) before
  // tearing down the accept sources so stop cannot leave hung handlers.
  __block NSArray<GCDWebServerConnection*>* connectionsToAbort = nil;
  dispatch_sync(_syncQueue, ^{
    connectionsToAbort = [self->_activeConnectionSet allObjects];
  });
  for (GCDWebServerConnection* connection in connectionsToAbort) {
    [connection abortForServerStop];
  }

  if (_dnsService) {
    _dnsAddress = nil;
    _dnsPort = 0;
    if (_dnsSource) {
      CFRunLoopSourceInvalidate(_dnsSource);
      CFRelease(_dnsSource);
      _dnsSource = NULL;
    }
    if (_dnsSocket) {
      CFRelease(_dnsSocket);
      _dnsSocket = NULL;
    }
    DNSServiceRefDeallocate(_dnsService);
    _dnsService = NULL;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (_registrationService) {
    if (_resolutionService) {
      CFNetServiceUnscheduleFromRunLoop(_resolutionService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
      CFNetServiceSetClient(_resolutionService, NULL, NULL);
      CFNetServiceCancel(_resolutionService);
      CFRelease(_resolutionService);
      _resolutionService = NULL;
    }
    CFNetServiceUnscheduleFromRunLoop(_registrationService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    CFNetServiceSetClient(_registrationService, NULL, NULL);
    CFNetServiceCancel(_registrationService);
    CFRelease(_registrationService);
    _registrationService = NULL;
  }
#pragma clang diagnostic pop

  dispatch_source_cancel(_source6);
  dispatch_source_cancel(_source4);
  dispatch_group_wait(_sourceGroup, DISPATCH_TIME_FOREVER);  // Wait until the cancellation handlers have been called which guarantees the listening sockets are closed
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
  dispatch_release(_source6);
#endif
  _source6 = NULL;
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
  dispatch_release(_source4);
#endif
  _source4 = NULL;
  _port = 0;
  _bindToLocalhost = NO;
  _enableKeepAlive = NO;
  _keepAliveIdleTimeout = 0;
  _maxRequestBodyLength = 0;
  _maxKeepAliveRequests = 0;

  _serverName = nil;
  _authenticationRealm = nil;
  _authenticationBasicAccounts = nil;
  _authenticationDigestAccounts = nil;

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_disconnectBlock) {
      dispatch_block_cancel(self->_disconnectBlock);
      self->_disconnectBlock = NULL;
      [self _didDisconnect];
    }
  });

  GWS_LOG_INFO(@"%@ stopped", [self class]);
  if ([_delegate respondsToSelector:@selector(webServerDidStop:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_delegate webServerDidStop:self];
    });
  }
}

#if TARGET_OS_IPHONE

- (void)_didEnterBackground:(NSNotification*)notification {
  GWS_DCHECK([NSThread isMainThread]);
  GWS_LOG_DEBUG(@"Did enter background");
  // GCD-4: hop off main — _stop waits on accept-source cancellation (dispatch_group_wait).
  if ((_backgroundTask == UIBackgroundTaskInvalid) && _source4) {
    dispatch_async(_lifecycleQueue, ^{
      if (self->_source4) {
        [self _stop];
      }
    });
  }
}

- (void)_willEnterForeground:(NSNotification*)notification {
  GWS_DCHECK([NSThread isMainThread]);
  GWS_LOG_DEBUG(@"Will enter foreground");
  if (!_source4) {
    dispatch_async(_lifecycleQueue, ^{
      if (!self->_source4) {
        [self _start:NULL];  // TODO: There's probably nothing we can do on failure
      }
    });
  }
}

#endif

- (BOOL)startWithOptions:(NSDictionary<NSString*, id>*)options error:(NSError**)error {
  if (_options == nil) {
    _options = options ? [options copy] : @{};
#if TARGET_OS_IPHONE
    _suspendInBackground = [(NSNumber*)_GetOption(_options, GCDWebServerOption_AutomaticallySuspendInBackground, @YES) boolValue];
    if (((_suspendInBackground == NO) || _GCDWebServerIsAppExtension() || ([[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground)) && ![self _start:error])
#else
    if (![self _start:error])
#endif
    {
      _options = nil;
      return NO;
    }
#if TARGET_OS_IPHONE
    if (_suspendInBackground) {
      [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
      [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_willEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
#endif
    return YES;
  } else {
    GWS_DNOT_REACHED();
  }
  return NO;
}

- (BOOL)isRunning {
  return (_options ? YES : NO);
}

- (void)stop {
  if ([NSThread isMainThread]) {
    GWS_LOG_WARNING(@"- [%@ stop] called on the main thread; this may block until listening sockets close. Prefer -stopWithCompletion:.", [self class]);
  }
  if (_options) {
#if TARGET_OS_IPHONE
    if (_suspendInBackground) {
      [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
      [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    }
#endif
    if (_source4) {
      [self _stop];
    }
    _options = nil;
  } else {
    GWS_DNOT_REACHED();
  }
}

// GCD-4: Non-blocking stop for main-thread / UI callers.
- (void)stopWithCompletion:(void (^)(void))completion {
  dispatch_async(_lifecycleQueue, ^{
    [self stop];
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), completion);
    }
  });
}

@end
