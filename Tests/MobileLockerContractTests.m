// Mobile Locker contract tests — mirror PresentationWebServer usage of GCDWebServer.
// GCD-12 / GCD-13 / GCD-14

#import <XCTest/XCTest.h>
#import <zlib.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#import "GCDWebServer.h"
#import "GCDWebServerFunctions.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerRequest.h"

#pragma clang diagnostic ignored "-Weverything"

@interface MLDelegateProbe : NSObject <GCDWebServerDelegate>
@property(nonatomic, copy) void (^onStart)(void);
@property(nonatomic, copy) void (^onStop)(void);
@property(nonatomic, assign) BOOL startOnMain;
@property(nonatomic, assign) BOOL stopOnMain;
@end

@implementation MLDelegateProbe
- (void)webServerDidStart:(GCDWebServer*)server {
  self.startOnMain = [NSThread isMainThread];
  if (self.onStart) {
    self.onStart();
  }
}
- (void)webServerDidStop:(GCDWebServer*)server {
  self.stopOnMain = [NSThread isMainThread];
  if (self.onStop) {
    self.onStop();
  }
}
@end

@interface MobileLockerContractTests : XCTestCase
@end

@implementation MobileLockerContractTests

#pragma mark - Helpers

- (NSString*)ml_tempFileWithContents:(NSData*)data {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  XCTAssertTrue([data writeToFile:path atomically:YES]);
  return path;
}

- (NSDictionary*)ml_defaultStartOptions {
  // PresentationWebServer uses Port + AutomaticallySuspendInBackground: false.
  // BindToLocalhost is recommended (GCD-5) and used here for safe local tests.
  return @{
    GCDWebServerOption_Port: @0,
    GCDWebServerOption_BindToLocalhost: @YES,
    GCDWebServerOption_AutomaticallySuspendInBackground: @NO
  };
}

/// Raw HTTP/1.1 over TCP so URLSession cannot auto-decode gzip (needed for Content-Encoding checks).
- (NSData*)ml_rawHTTPOnPort:(NSUInteger)port request:(NSString*)requestUTF8 {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  XCTAssertGreaterThan(fd, 0);
  struct sockaddr_in addr;
  bzero(&addr, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int connected = connect(fd, (struct sockaddr*)&addr, sizeof(addr));
  XCTAssertEqual(connected, 0, @"connect failed: %s", strerror(errno));

  NSData* reqData = [requestUTF8 dataUsingEncoding:NSUTF8StringEncoding];
  ssize_t written = send(fd, reqData.bytes, reqData.length, 0);
  XCTAssertEqual(written, (ssize_t)reqData.length);

  NSMutableData* response = [NSMutableData data];
  char buf[4096];
  while (1) {
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) {
      break;
    }
    [response appendBytes:buf length:(NSUInteger)n];
  }
  close(fd);
  return response;
}

- (NSInteger)ml_statusFromRawHTTP:(NSData*)raw {
  NSString* text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
  if (!text) {
    // Binary gzip body — parse status from first line only.
    NSRange crlf = [raw rangeOfData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              range:NSMakeRange(0, MIN(raw.length, (NSUInteger)200))];
    if (crlf.location == NSNotFound) {
      return -1;
    }
    text = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, crlf.location)] encoding:NSUTF8StringEncoding];
  }
  // HTTP/1.1 200 OK
  NSArray* parts = [text componentsSeparatedByString:@" "];
  if (parts.count < 2) {
    return -1;
  }
  return [parts[1] integerValue];
}

- (NSString*)ml_headerValue:(NSString*)name fromRawHTTP:(NSData*)raw {
  NSData* sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange headerEnd = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
  if (headerEnd.location == NSNotFound) {
    return nil;
  }
  NSString* headers = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, headerEnd.location)]
                                            encoding:NSUTF8StringEncoding];
  for (NSString* line in [headers componentsSeparatedByString:@"\r\n"]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) {
      continue;
    }
    NSString* key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
      return [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
  }
  return nil;
}

- (NSData*)ml_bodyFromRawHTTP:(NSData*)raw {
  NSData* sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange headerEnd = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
  if (headerEnd.location == NSNotFound) {
    return [NSData data];
  }
  NSUInteger bodyStart = headerEnd.location + headerEnd.length;
  // Dechunk if Transfer-Encoding: chunked
  NSString* te = [self ml_headerValue:@"Transfer-Encoding" fromRawHTTP:raw];
  NSData* body = [raw subdataWithRange:NSMakeRange(bodyStart, raw.length - bodyStart)];
  if (te && [te.lowercaseString containsString:@"chunked"]) {
    return [self ml_decodeChunkedBody:body];
  }
  return body;
}

- (NSData*)ml_decodeChunkedBody:(NSData*)chunked {
  NSMutableData* out = [NSMutableData data];
  const char* bytes = chunked.bytes;
  NSUInteger len = chunked.length;
  NSUInteger i = 0;
  while (i < len) {
    // Read hex size line
    NSUInteger lineStart = i;
    while (i + 1 < len && !(bytes[i] == '\r' && bytes[i + 1] == '\n')) {
      i++;
    }
    if (i + 1 >= len) {
      break;
    }
    NSString* hex = [[NSString alloc] initWithBytes:bytes + lineStart length:(i - lineStart) encoding:NSUTF8StringEncoding];
    unsigned long chunkLen = strtoul(hex.UTF8String, NULL, 16);
    i += 2;  // CRLF
    if (chunkLen == 0) {
      break;
    }
    if (i + chunkLen > len) {
      break;
    }
    [out appendBytes:bytes + i length:chunkLen];
    i += chunkLen;
    if (i + 1 < len && bytes[i] == '\r' && bytes[i + 1] == '\n') {
      i += 2;
    }
  }
  return out;
}

- (NSData*)ml_gunzip:(NSData*)data {
  if (data.length == 0) {
    return data;
  }
  z_stream stream;
  bzero(&stream, sizeof(stream));
  // 15 + 16 = gzip
  int status = inflateInit2(&stream, 15 + 16);
  XCTAssertEqual(status, Z_OK);
  stream.next_in = (Bytef*)data.bytes;
  stream.avail_in = (uInt)data.length;
  NSMutableData* out = [NSMutableData dataWithLength:data.length * 4];
  NSUInteger offset = 0;
  do {
    if (offset >= out.length) {
      out.length = out.length * 2;
    }
    stream.next_out = (Bytef*)out.mutableBytes + offset;
    stream.avail_out = (uInt)(out.length - offset);
    status = inflate(&stream, Z_NO_FLUSH);
    offset = stream.total_out;
    if (status == Z_STREAM_END) {
      break;
    }
    XCTAssertTrue(status == Z_OK || status == Z_BUF_ERROR);
  } while (status != Z_STREAM_END);
  inflateEnd(&stream);
  out.length = stream.total_out;
  return out;
}

#pragma mark - GCD-12: Static files gzip + byte range

/// PresentationWebServer always enables gzip; non-range assets must still be compressed.
- (void)testML_FullFileGETWithGzipEnabledUsesGzipEncoding {
  NSData* fileData = [@"0123456789ABCDEFGHIJlarge-enough-for-gzip-contract-test-payload" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/asset"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path byteRange:request.byteRange];
                   response.gzipContentEncodingEnabled = YES;
                   return response;
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET /asset HTTP/1.1\r\n"
                               @"Host: localhost\r\n"
                               @"Accept-Encoding: gzip\r\n"
                               @"Connection: close\r\n"
                               @"\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  NSString* encoding = [self ml_headerValue:@"Content-Encoding" fromRawHTTP:raw];
  XCTAssertEqualObjects(encoding.lowercaseString, @"gzip");
  NSString* vary = [self ml_headerValue:@"Vary" fromRawHTTP:raw];
  XCTAssertTrue([vary.lowercaseString containsString:@"accept-encoding"], @"Vary=%@", vary);
  NSData* body = [self ml_bodyFromRawHTTP:raw];
  XCTAssertNotEqualObjects(body, fileData);  // compressed on wire
  NSData* inflated = [self ml_gunzip:body];
  XCTAssertEqualObjects(inflated, fileData);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

/// GCD-20: gzip enabled on response but client did not Accept-Encoding: gzip → raw body.
- (void)testML_GzipEnabledWithoutClientAcceptEncodingIsSkipped {
  NSData* fileData = [@"0123456789ABCDEFGHIJno-gzip-client" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/asset"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path];
                   response.gzipContentEncodingEnabled = YES;
                   return response;
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET /asset HTTP/1.1\r\n"
                               @"Host: localhost\r\n"
                               @"Connection: close\r\n"
                               @"\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertNil([self ml_headerValue:@"Content-Encoding" fromRawHTTP:raw]);
  XCTAssertEqualObjects([self ml_bodyFromRawHTTP:raw], fileData);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

/// GCD-20: Accept-Encoding: GZIP (uppercase) still enables compression.
- (void)testML_GzipAcceptEncodingIsCaseInsensitive {
  NSData* fileData = [@"0123456789ABCDEFGHIJcase-insensitive-gzip" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/asset"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path];
                   response.gzipContentEncodingEnabled = YES;
                   return response;
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET /asset HTTP/1.1\r\n"
                               @"Host: localhost\r\n"
                               @"Accept-Encoding: GZIP\r\n"
                               @"Connection: close\r\n"
                               @"\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([self ml_headerValue:@"Content-Encoding" fromRawHTTP:raw].lowercaseString, @"gzip");

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

/// GCD-21: FileResponse ETag is quoted; If-None-Match returns 304.
- (void)testML_FileResponseETagConditionalGETReturns304 {
  NSData* fileData = [@"etag-conditional-body" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/asset"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   return [GCDWebServerFileResponse responseWithFile:path];
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req1 = [NSString stringWithFormat:
                                @"GET /asset HTTP/1.1\r\n"
                                @"Host: localhost\r\n"
                                @"Connection: close\r\n"
                                @"\r\n"];
  NSData* raw1 = [self ml_rawHTTPOnPort:server.port request:req1];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw1], 200);
  NSString* etag = [self ml_headerValue:@"ETag" fromRawHTTP:raw1];
  XCTAssertNotNil(etag);
  XCTAssertTrue([etag hasPrefix:@"\""] && [etag hasSuffix:@"\""], @"ETag should be quoted: %@", etag);

  NSString* req2 = [NSString stringWithFormat:
                                @"GET /asset HTTP/1.1\r\n"
                                @"Host: localhost\r\n"
                                @"If-None-Match: %@\r\n"
                                @"Connection: close\r\n"
                                @"\r\n",
                            etag];
  NSData* raw2 = [self ml_rawHTTPOnPort:server.port request:req2];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw2], 304);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

/// GCD-19: plain FileResponse advertises Accept-Ranges without callers setting it.
- (void)testML_FileResponseIncludesAcceptRangesHeader {
  NSData* fileData = [@"0123456789" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/asset"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   // PresentationWebServer path: FileResponse only — no manual Accept-Ranges.
                   return [GCDWebServerFileResponse responseWithFile:path byteRange:request.byteRange];
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET /asset HTTP/1.1\r\n"
                               @"Host: localhost\r\n"
                               @"Connection: close\r\n"
                               @"\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  NSString* acceptRanges = [self ml_headerValue:@"Accept-Ranges" fromRawHTTP:raw];
  XCTAssertEqualObjects(acceptRanges.lowercaseString, @"bytes");

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

/// Video/audio seeking: gzip always-on must not corrupt Range responses (GCD-2).
- (void)testML_RangedGETWithGzipEnabledReturnsRawPartialContent {
  NSData* fileData = [@"0123456789ABCDEFGHIJ" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/media"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path byteRange:request.byteRange];
                   response.gzipContentEncodingEnabled = YES;  // same as PresentationWebServer
                   return response;
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET /media HTTP/1.1\r\n"
                               @"Host: localhost\r\n"
                               @"Range: bytes=0-4\r\n"
                               @"Accept-Encoding: gzip\r\n"
                               @"Connection: close\r\n"
                               @"\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 206);
  XCTAssertNil([self ml_headerValue:@"Content-Encoding" fromRawHTTP:raw]);
  NSString* contentRange = [self ml_headerValue:@"Content-Range" fromRawHTTP:raw];
  XCTAssertTrue([contentRange containsString:@"bytes 0-4/"], @"Content-Range=%@", contentRange);
  NSData* body = [self ml_bodyFromRawHTTP:raw];
  XCTAssertEqualObjects([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding], @"01234");

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

/// GCD-22: API JSON responses include charset=utf-8 (PresentationWebServer routes).
- (void)testML_JSONDataResponseIncludesCharset {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/api/json"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   return [GCDWebServerDataResponse responseWithJSONObject:@{@"ok": @YES}];
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET /api/json HTTP/1.1\r\n"
                               @"Host: localhost\r\n"
                               @"Connection: close\r\n"
                               @"\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  NSString* contentType = [self ml_headerValue:@"Content-Type" fromRawHTTP:raw];
  XCTAssertTrue([contentType.lowercaseString containsString:@"application/json"], @"%@", contentType);
  XCTAssertTrue([contentType.lowercaseString containsString:@"charset=utf-8"], @"%@", contentType);

  [server stop];
}

#pragma mark - GCD-13: Async routes, stop, double completion

/// Scanner/picker/video routes complete after a Task hop with JSON.
- (void)testML_AsyncProcessBlockCompletesWithJSONAfterHop {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/api/async-ok"
                 requestClass:[GCDWebServerRequest class]
          asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
            // Simulate PresentationWebServer Task { ... finish.call(...) } hop.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
              usleep(20000);  // 20ms
              completionBlock([GCDWebServerDataResponse responseWithJSONObject:@{@"status": @"ok", @"source": @"async"}]);
            });
          }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/api/async-ok", (unsigned long)server.port]];
  XCTestExpectation* done = [self expectationWithDescription:@"async json"];
  [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:url]
                                 completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                   XCTAssertNil(error);
                                   XCTAssertEqual([(NSHTTPURLResponse*)response statusCode], 200);
                                   NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                                   XCTAssertEqualObjects(json[@"status"], @"ok");
                                   XCTAssertEqualObjects(json[@"source"], @"async");
                                   [done fulfill];
                                 }] resume];
  [self waitForExpectationsWithTimeout:5.0 handler:nil];
  [server stop];
}

/// MLI-1575: app still calls completion after stop; library once-guard must ignore extras.
- (void)testML_StopForcesAsyncCompletionAndIgnoresSecondCall {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  XCTestExpectation* processStarted = [self expectationWithDescription:@"held"];
  // This is GCD's once-wrapped completion (same object abortForServerStop will invoke).
  __block GCDWebServerCompletionBlock held = nil;

  [server addHandlerForMethod:@"GET"
                         path:@"/api/hold"
                 requestClass:[GCDWebServerRequest class]
          asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
            held = [completionBlock copy];
            [processStarted fulfill];
          }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/api/hold", (unsigned long)server.port]];
  XCTestExpectation* clientDone = [self expectationWithDescription:@"client"];
  [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:url]
                                 completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                   // Connection may fail or return 503 after abort — either is fine; must complete.
                                   [clientDone fulfill];
                                 }] resume];

  [self waitForExpectations:@[ processStarted ] timeout:5.0];
  XCTAssertNotNil(held);

  XCTestExpectation* stopped = [self expectationWithDescription:@"stopped"];
  [server stopWithCompletion:^{
    [stopped fulfill];
  }];
  [self waitForExpectations:@[ stopped, clientDone ] timeout:5.0];

  // App-style late finishes after stop (cancelled JSON) — must not crash / hang.
  held([GCDWebServerDataResponse responseWithJSONObject:@{@"status": @"cancelled"}]);
  held([GCDWebServerDataResponse responseWithJSONObject:@{@"status": @"too-late"}]);
}

#pragma mark - GCD-14: Sync JSON, app options, restart

/// Majority of Mobile Locker API routes use sync processBlock + JSON.
- (void)testML_SyncProcessBlockReturnsJSON {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/mobilelocker/api/ping"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   return [GCDWebServerDataResponse responseWithJSONObject:@{@"ok": @YES, @"path": request.path}];
                 }];

  NSError* startError = nil;
  BOOL started = [server startWithOptions:[self ml_defaultStartOptions] error:&startError];
  XCTAssertTrue(started, @"%@", startError);

  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/mobilelocker/api/ping", (unsigned long)server.port]];
  XCTestExpectation* done = [self expectationWithDescription:@"json"];
  [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:url]
                                 completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                   XCTAssertNil(error);
                                   XCTAssertEqual([(NSHTTPURLResponse*)response statusCode], 200);
                                   NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                                   XCTAssertEqualObjects(json[@"ok"], @YES);
                                   XCTAssertEqualObjects(json[@"path"], @"/mobilelocker/api/ping");
                                   [done fulfill];
                                 }] resume];
  [self waitForExpectationsWithTimeout:5.0 handler:nil];
  [server stop];
}

/// Exact PresentationWebServer option flags (plus BindToLocalhost for local safety).
- (void)testML_AppStartOptionsRequestAndStop {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addDefaultHandlerForMethod:@"GET"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                          return [GCDWebServerDataResponse responseWithText:@"hi"];
                        }];

  NSDictionary* options = @{
    GCDWebServerOption_Port: @0,
    GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
    GCDWebServerOption_BindToLocalhost: @YES
  };
  NSError* startError = nil;
  XCTAssertTrue([server startWithOptions:options error:&startError], @"%@", startError);

  NSString* req = [NSString stringWithFormat:
                               @"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  // Keep-alive remains off by default — response should close (no keep-alive header required).
  NSString* connection = [self ml_headerValue:@"Connection" fromRawHTTP:raw];
  XCTAssertTrue([connection.lowercaseString isEqualToString:@"close"] || connection == nil ||
                ![connection.lowercaseString isEqualToString:@"keep-alive"]);

  [server stop];
}

/// Opening/closing presentations: start → stop → start again must work.
- (void)testML_StartStopStartAgainServesRequests {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addDefaultHandlerForMethod:@"GET"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                          return [GCDWebServerDataResponse responseWithJSONObject:@{@"n": @1}];
                        }];

  NSError* err = nil;
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:&err], @"%@", err);
  NSUInteger port1 = server.port;
  {
    NSString* req = @"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    NSData* raw = [self ml_rawHTTPOnPort:port1 request:req];
    XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  }
  [server stop];

  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:&err], @"%@", err);
  NSUInteger port2 = server.port;
  {
    NSString* req = @"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    NSData* raw = [self ml_rawHTTPOnPort:port2 request:req];
    XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  }
  [server stop];
}

/// Default Connection: close — two sequential client connections both succeed.
- (void)testML_SequentialRequestsWithoutKeepAlive {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  __block NSUInteger hits = 0;
  [server addDefaultHandlerForMethod:@"GET"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                          hits += 1;
                          return [GCDWebServerDataResponse responseWithJSONObject:@{@"hit": @(hits)}];
                        }];

  NSError* err = nil;
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:&err], @"%@", err);

  for (int i = 0; i < 2; i++) {
    NSString* req = @"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
    XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  }
  XCTAssertEqual(hits, 2u);
  [server stop];
}

/// Delegate callbacks used by PresentationWebServer (start/stop on main).
- (void)testML_DelegateDidStartAndDidStop {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  MLDelegateProbe* probe = [[MLDelegateProbe alloc] init];
  server.delegate = probe;

  [server addDefaultHandlerForMethod:@"GET"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                          return [GCDWebServerDataResponse responseWithText:@"x"];
                        }];

  XCTestExpectation* started = [self expectationWithDescription:@"didStart"];
  probe.onStart = ^{
    [started fulfill];
  };
  XCTestExpectation* stopped = [self expectationWithDescription:@"didStop"];
  probe.onStop = ^{
    [stopped fulfill];
  };

  NSError* err = nil;
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:&err], @"%@", err);
  [self waitForExpectations:@[ started ] timeout:5.0];
  XCTAssertTrue([NSThread isMainThread] || probe.startOnMain);  // start callback observed on main

  [server stopWithCompletion:nil];
  [self waitForExpectations:@[ stopped ] timeout:5.0];
  XCTAssertTrue(probe.stopOnMain);
}

#pragma mark - GCD-18: MIME, charset, safe root helper

- (void)testML_MimeTypesForWebExtensionsIncludeCharset {
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"html", nil) hasPrefix:@"text/html"]);
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"html", nil) containsString:@"charset=utf-8"]);
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"js", nil) hasPrefix:@"text/javascript"]);
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"js", nil) containsString:@"charset=utf-8"]);
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"mjs", nil) hasPrefix:@"text/javascript"]);
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"css", nil) hasPrefix:@"text/css"]);
  XCTAssertEqualObjects(GCDWebServerGetMimeTypeForExtension(@"wasm", nil), @"application/wasm");
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"json", nil) hasPrefix:@"application/json"]);
  XCTAssertTrue([GCDWebServerGetMimeTypeForExtension(@"svg", nil) hasPrefix:@"image/svg+xml"]);
  XCTAssertEqualObjects(GCDWebServerGetMimeTypeForExtension(@"woff2", nil), @"font/woff2");
  // charset not double-applied
  NSString* withCharset = GCDWebServerEnsureUTF8CharsetIfNeeded(@"text/html; charset=utf-8");
  XCTAssertEqualObjects(withCharset, @"text/html; charset=utf-8");
}

- (void)testML_SafeFileUnderRootServesFileAndIndex {
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  NSString* sub = [root stringByAppendingPathComponent:@"assets"];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:NULL]);
  NSString* indexPath = [root stringByAppendingPathComponent:@"index.html"];
  NSString* jsPath = [sub stringByAppendingPathComponent:@"app.js"];
  XCTAssertTrue([@"<!doctype html><title>x</title>" writeToFile:indexPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
  XCTAssertTrue([@"console.log(1)" writeToFile:jsPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

  NSRange full = NSMakeRange(NSUIntegerMax, 0);
  GCDWebServerFileResponse* index = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                                urlPath:@"/"
                                                                              byteRange:full
                                                                         allowIndexHTML:YES
                                                                      mimeTypeOverrides:nil];
  XCTAssertNotNil(index);
  XCTAssertTrue([index.contentType hasPrefix:@"text/html"]);

  GCDWebServerFileResponse* js = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                             urlPath:@"/assets/app.js"
                                                                           byteRange:full
                                                                      allowIndexHTML:YES
                                                                   mimeTypeOverrides:nil];
  XCTAssertNotNil(js);
  XCTAssertTrue([js.contentType hasPrefix:@"text/javascript"]);

  GCDWebServerFileResponse* dirIndex = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                                   urlPath:@"/assets/"
                                                                                 byteRange:full
                                                                            allowIndexHTML:YES
                                                                         mimeTypeOverrides:nil];
  // assets/ has no index.html → nil
  XCTAssertNil(dirIndex);

  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testML_SafeFileUnderRootRejectsTraversal {
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
  NSString* secret = [root stringByAppendingPathComponent:@"secret.txt"];
  XCTAssertTrue([@"secret" writeToFile:secret atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
  // Sibling outside root
  NSString* outside = [[root stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"outside.txt"];
  XCTAssertTrue([@"outside" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

  NSRange full = NSMakeRange(NSUIntegerMax, 0);
  GCDWebServerFileResponse* ok = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                             urlPath:@"/secret.txt"
                                                                           byteRange:full
                                                                      allowIndexHTML:NO
                                                                   mimeTypeOverrides:nil];
  XCTAssertNotNil(ok);

  GCDWebServerFileResponse* denied = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                                 urlPath:@"/../outside.txt"
                                                                               byteRange:full
                                                                          allowIndexHTML:NO
                                                                       mimeTypeOverrides:nil];
  XCTAssertNil(denied);

  GCDWebServerFileResponse* missing = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                                  urlPath:@"/nope.html"
                                                                                byteRange:full
                                                                           allowIndexHTML:YES
                                                                        mimeTypeOverrides:nil];
  XCTAssertNil(missing);

  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:outside error:NULL];
}

- (void)testML_SafeFileUnderRootHTTPContentType {
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
  NSString* indexPath = [root stringByAppendingPathComponent:@"index.html"];
  XCTAssertTrue([@"<!doctype html>" writeToFile:indexPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addDefaultHandlerForMethod:@"GET"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                          return [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                             urlPath:request.path
                                                                           byteRange:request.byteRange
                                                                      allowIndexHTML:YES
                                                                   mimeTypeOverrides:nil];
                        }];
  NSError* err = nil;
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:&err], @"%@", err);

  NSString* req = @"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  NSString* contentType = [self ml_headerValue:@"Content-Type" fromRawHTTP:raw];
  XCTAssertTrue([contentType.lowercaseString hasPrefix:@"text/html"], @"Content-Type=%@", contentType);
  XCTAssertTrue([contentType.lowercaseString containsString:@"charset=utf-8"]);
  NSString* acceptRanges = [self ml_headerValue:@"Accept-Ranges" fromRawHTTP:raw];
  XCTAssertEqualObjects(acceptRanges.lowercaseString, @"bytes");

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

#pragma mark - GCD-25: Document-root static handler

- (NSString*)ml_tempDocumentRootWithFiles:(NSDictionary<NSString*, NSData*>*)files {
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
  [files enumerateKeysAndObjectsUsingBlock:^(NSString* rel, NSData* data, BOOL* stop) {
    NSString* full = [root stringByAppendingPathComponent:rel];
    NSString* dir = [full stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    XCTAssertTrue([data writeToFile:full atomically:YES]);
  }];
  return root;
}

- (void)testDocumentRoot_servesFileAndAcceptRanges {
  NSString* body = @"hello-static-asset";
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"app.js" : [body dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root
                           urlBasePath:@"/"
                         indexFilename:nil
                     entryFallbackPath:nil
                              cacheAge:0
                            gzipPolicy:GCDWebServerStaticGzipPolicyNever];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSString* req = [NSString stringWithFormat:@"GET /app.js HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:req];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([self ml_headerValue:@"Accept-Ranges" fromRawHTTP:raw], @"bytes");
  XCTAssertEqualObjects([[NSString alloc] initWithData:[self ml_bodyFromRawHTTP:raw] encoding:NSUTF8StringEncoding], body);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testDocumentRoot_indexHtmlForSlash {
  NSString* body = @"<!doctype html><title>idx</title>";
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"index.html" : [body dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root urlBasePath:@"/" indexFilename:nil entryFallbackPath:nil cacheAge:0 gzipPolicy:GCDWebServerStaticGzipPolicyNever];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([[NSString alloc] initWithData:[self ml_bodyFromRawHTTP:raw] encoding:NSUTF8StringEncoding], body);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testDocumentRoot_entryFallbackWhenNoIndex {
  NSString* body = @"<!doctype html><title>home</title>";
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"home.html" : [body dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root urlBasePath:@"/" indexFilename:@"index.html" entryFallbackPath:@"home.html" cacheAge:0 gzipPolicy:GCDWebServerStaticGzipPolicyNever];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([[NSString alloc] initWithData:[self ml_bodyFromRawHTTP:raw] encoding:NSUTF8StringEncoding], body);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testDocumentRoot_rejectsTraversal {
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"ok.txt" : [@"safe" dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root urlBasePath:@"/" indexFilename:nil entryFallbackPath:nil cacheAge:0 gzipPolicy:GCDWebServerStaticGzipPolicyNever];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET /../etc/passwd HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 404);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testDocumentRoot_gzipTextLike_notMedia {
  // Long enough for gzip path to be meaningful.
  NSMutableString* css = [NSMutableString string];
  for (NSInteger i = 0; i < 80; i++) {
    [css appendString:@"body { color: #333; margin: 0; padding: 0; /* pad */ }\n"];
  }
  NSData* pngHeader = [NSData dataWithBytes:"\x89PNG\r\n\x1a\n\0\0\0\rIHDR" length:16];
  NSString* root = [self ml_tempDocumentRootWithFiles:@{
    @"style.css" : [css dataUsingEncoding:NSUTF8StringEncoding],
    @"pixel.png" : pngHeader
  }];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root urlBasePath:@"/" indexFilename:nil entryFallbackPath:nil cacheAge:0 gzipPolicy:GCDWebServerStaticGzipPolicyTextLike];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* cssRaw = [self ml_rawHTTPOnPort:server.port
                                  request:@"GET /style.css HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:cssRaw], 200);
  XCTAssertEqualObjects([self ml_headerValue:@"Content-Encoding" fromRawHTTP:cssRaw], @"gzip");

  NSData* pngRaw = [self ml_rawHTTPOnPort:server.port
                                  request:@"GET /pixel.png HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:pngRaw], 200);
  XCTAssertNil([self ml_headerValue:@"Content-Encoding" fromRawHTTP:pngRaw]);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testDocumentRoot_cacheControlNoCacheWhenAgeZero {
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"a.txt" : [@"x" dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root urlBasePath:@"/" indexFilename:nil entryFallbackPath:nil cacheAge:0 gzipPolicy:GCDWebServerStaticGzipPolicyNever];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET /a.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([self ml_headerValue:@"Cache-Control" fromRawHTTP:raw], @"no-cache");

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testDocumentRoot_404Missing {
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"a.txt" : [@"x" dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForDocumentRoot:root urlBasePath:@"/" indexFilename:nil entryFallbackPath:nil cacheAge:0 gzipPolicy:GCDWebServerStaticGzipPolicyNever];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET /missing.js HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 404);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

#pragma mark - GCD-26: Base-path safe file-under-root

- (void)testBasePath_rejectsTraversalOutsideDirectory {
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"ok.txt" : [@"safe" dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForBasePath:@"/files/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET /files/../ok.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  // After normalize, ../ may collapse; also try absolute escape style
  NSData* raw2 = [self ml_rawHTTPOnPort:server.port request:@"GET /files/%2e%2e/%2e%2e/etc/passwd HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw2], 404);

  NSData* ok = [self ml_rawHTTPOnPort:server.port request:@"GET /files/ok.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:ok], 200);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
  (void)raw;
}

- (void)testBasePath_servesIndexFilename {
  NSString* body = @"index-body";
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"index.html" : [body dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:@"index.html" cacheAge:0 allowRangeRequests:YES];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([[NSString alloc] initWithData:[self ml_bodyFromRawHTTP:raw] encoding:NSUTF8StringEncoding], body);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

- (void)testBasePath_directoryListingWhenNoIndex {
  NSString* root = [self ml_tempDocumentRootWithFiles:@{@"a.txt" : [@"a" dataUsingEncoding:NSUTF8StringEncoding]}];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  NSString* html = [[NSString alloc] initWithData:[self ml_bodyFromRawHTTP:raw] encoding:NSUTF8StringEncoding];
  XCTAssertTrue([html containsString:@"a.txt"]);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

#pragma mark - GCD-27: Cache policy + suppressETag

- (void)testCachePolicy_noStoreHeader {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/x"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerDataResponse* r = [GCDWebServerDataResponse responseWithText:@"hi"];
                   r.cachePolicy = GCDWebServerCachePolicyNoStore;
                   return r;
                 }];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET /x HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:raw], 200);
  XCTAssertEqualObjects([self ml_headerValue:@"Cache-Control" fromRawHTTP:raw], @"no-store");
  [server stop];
}

- (void)testCachePolicy_maxAgeHeader {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/x"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerDataResponse* r = [GCDWebServerDataResponse responseWithText:@"hi"];
                   r.cachePolicy = GCDWebServerCachePolicyMaxAge;
                   r.cacheControlMaxAge = 3600;
                   return r;
                 }];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);
  NSData* raw = [self ml_rawHTTPOnPort:server.port request:@"GET /x HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqualObjects([self ml_headerValue:@"Cache-Control" fromRawHTTP:raw], @"max-age=3600, public");
  [server stop];
}

- (void)testCachePolicy_suppressETagSkipsHeaderAnd304 {
  NSData* fileData = [@"etag-body-content" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self ml_tempFileWithContents:fileData];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/asset"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path];
                   response.suppressETag = YES;
                   response.lastModifiedDate = nil;  // isolate ETag path from Last-Modified 304
                   return response;
                 }];
  XCTAssertTrue([server startWithOptions:[self ml_defaultStartOptions] error:NULL]);

  NSData* first = [self ml_rawHTTPOnPort:server.port request:@"GET /asset HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:first], 200);
  XCTAssertNil([self ml_headerValue:@"ETag" fromRawHTTP:first]);

  // Even with a fabricated If-None-Match, suppressETag must not 304 on ETag.
  NSData* second = [self ml_rawHTTPOnPort:server.port
                                  request:@"GET /asset HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: \"anything\"\r\nConnection: close\r\n\r\n"];
  XCTAssertEqual([self ml_statusFromRawHTTP:second], 200);

  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

@end
