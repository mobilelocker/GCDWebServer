// SPM test target — mirrors Frameworks/Tests.m with module-compatible imports.
// The Xcode-based test suite in Frameworks/Tests.m remains the primary runner.

#import <XCTest/XCTest.h>
#import "GCDWebServer.h"
#import "GCDWebServerFunctions.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebDAVServer.h"
#import "GCDWebUploader.h"

#pragma clang diagnostic ignored "-Weverything"

@interface GCDWebServerTests : XCTestCase
@end

@implementation GCDWebServerTests

- (NSString*)_tempFileWithContents:(NSData*)data {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  XCTAssertTrue([data writeToFile:path atomically:YES]);
  return path;
}

- (void)testWebServer {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  XCTAssertNotNil(server);
}

- (void)testDAVServer {
  GCDWebDAVServer* server = [[GCDWebDAVServer alloc] init];
  XCTAssertNotNil(server);
}

- (void)testWebUploader {
  GCDWebUploader* server = [[GCDWebUploader alloc] init];
  XCTAssertNotNil(server);
}

- (void)testPaths {
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@""), @"");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/"), @"/foo");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/bar"), @"foo/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo//bar"), @"foo/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/./bar"), @"foo/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/../bar"), @"bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/../bar"), @"/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/.."), @"/");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@".."), @"");
}

- (void)testURLEscaping {
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@":"), @"%3A");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"@"), @"%40");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"/"), @"%2F");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"?"), @"%3F");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"&"), @"%26");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"="), @"%3D");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"+"), @"%2B");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"abc"), @"abc");
  NSString* roundtripped = GCDWebServerUnescapeURLString(GCDWebServerEscapeURLString(@"hello world: foo/bar?baz=qux&quux+corge"));
  XCTAssertEqualObjects(roundtripped, @"hello world: foo/bar?baz=qux&quux+corge");
}

- (void)testHeaderSanitization {
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"application/json"), @"application/json");
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"foo\rbar"), @"foobar");
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"foo\nbar"), @"foobar");
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"foo\r\nX-Injected: evil"), @"fooX-Injected: evil");
}

- (void)testChunkedTransferEncoding {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  __block NSData* receivedBody = nil;
  [server addHandlerForMethod:@"POST"
                         path:@"/echo"
                 requestClass:[GCDWebServerDataRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   receivedBody = [(GCDWebServerDataRequest*)request data];
                   return [GCDWebServerResponse responseWithStatusCode:200];
                 }];
  NSError* startError = nil;
  BOOL started = [server startWithOptions:@{GCDWebServerOption_Port: @0,
                                             GCDWebServerOption_BindToLocalhost: @YES}
                                    error:&startError];
  XCTAssertTrue(started, @"Server failed to start: %@", startError);
  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/echo", (unsigned long)server.port]];
  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  NSData* body = [@"Hello, chunked world!" dataUsingEncoding:NSUTF8StringEncoding];
  req.HTTPBody = body;
  [req setValue:@"chunked" forHTTPHeaderField:@"Transfer-Encoding"];
  [req setValue:nil forHTTPHeaderField:@"Content-Length"];
  XCTestExpectation* done = [self expectationWithDescription:@"request complete"];
  [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    XCTAssertNil(error);
    XCTAssertEqual([(NSHTTPURLResponse*)response statusCode], 200);
    [done fulfill];
  }] resume];
  [self waitForExpectationsWithTimeout:5.0 handler:nil];
  XCTAssertEqualObjects(receivedBody, body);
  [server stop];
}

// GCD-2 / GCD-8: ranged GET with gzip enabled must not apply Content-Encoding: gzip.
- (void)testRangeResponseSkipsGzip {
  NSData* fileData = [@"0123456789ABCDEFGHIJ" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self _tempFileWithContents:fileData];
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addHandlerForMethod:@"GET"
                         path:@"/file"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path byteRange:request.byteRange];
                   response.gzipContentEncodingEnabled = YES;
                   return response;
                 }];
  NSError* startError = nil;
  XCTAssertTrue([server startWithOptions:@{GCDWebServerOption_Port: @0, GCDWebServerOption_BindToLocalhost: @YES} error:&startError], @"%@", startError);
  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/file", (unsigned long)server.port]];
  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
  [req setValue:@"bytes=0-4" forHTTPHeaderField:@"Range"];
  [req setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
  XCTestExpectation* done = [self expectationWithDescription:@"range"];
  [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    XCTAssertNil(error);
    NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
    XCTAssertEqual(http.statusCode, 206);
    XCTAssertNil(http.allHeaderFields[@"Content-Encoding"]);
    XCTAssertEqualObjects([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], @"01234");
    [done fulfill];
  }] resume];
  [self waitForExpectationsWithTimeout:5.0 handler:nil];
  [server stop];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

// GCD-9: unsatisfiable range → 416
- (void)testUnsatisfiableRangeReturns416 {
  NSData* fileData = [@"short" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* path = [self _tempFileWithContents:fileData];
  GCDWebServerFileResponse* response = [GCDWebServerFileResponse responseWithFile:path byteRange:NSMakeRange(100, 10)];
  XCTAssertNotNil(response);
  XCTAssertEqual(response.statusCode, 416);
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

// GCD-5: localhostServerURL
- (void)testLocalhostServerURL {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  [server addDefaultHandlerForMethod:@"GET"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                          return [GCDWebServerDataResponse responseWithText:@"ok"];
                        }];
  NSError* startError = nil;
  XCTAssertTrue([server startWithOptions:@{GCDWebServerOption_Port: @0, GCDWebServerOption_BindToLocalhost: @YES} error:&startError], @"%@", startError);
  NSURL* local = server.localhostServerURL;
  XCTAssertNotNil(local);
  XCTAssertEqualObjects(local.host, @"localhost");
  XCTAssertEqual(local.port.unsignedIntegerValue, server.port);
  [server stop];
}

// GCD-3: async handler + stop must not hang
- (void)testStopAbortsPendingAsyncHandler {
  GCDWebServer* server = [[GCDWebServer alloc] init];
  XCTestExpectation* processStarted = [self expectationWithDescription:@"process started"];
  __block GCDWebServerCompletionBlock heldCompletion = nil;
  [server addHandlerForMethod:@"GET"
                         path:@"/hold"
                 requestClass:[GCDWebServerRequest class]
          asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
            heldCompletion = [completionBlock copy];
            [processStarted fulfill];
          }];
  NSError* startError = nil;
  XCTAssertTrue([server startWithOptions:@{GCDWebServerOption_Port: @0, GCDWebServerOption_BindToLocalhost: @YES} error:&startError], @"%@", startError);
  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/hold", (unsigned long)server.port]];
  XCTestExpectation* clientDone = [self expectationWithDescription:@"client"];
  [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:url]
                                 completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                   // Connection may fail or return 503 after abort — either is fine; must complete.
                                   [clientDone fulfill];
                                 }] resume];
  [self waitForExpectations:@[ processStarted ] timeout:5.0];
  XCTestExpectation* stopped = [self expectationWithDescription:@"stopped"];
  [server stopWithCompletion:^{
    [stopped fulfill];
  }];
  [self waitForExpectations:@[ stopped, clientDone ] timeout:5.0];
  // Late completion must be safe (ignored).
  if (heldCompletion) {
    heldCompletion([GCDWebServerDataResponse responseWithText:@"late"]);
  }
}

@end
