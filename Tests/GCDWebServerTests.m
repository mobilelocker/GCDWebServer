// SPM test target — mirrors Frameworks/Tests.m with module-compatible imports.
// The Xcode-based test suite in Frameworks/Tests.m remains the primary runner.

#import <XCTest/XCTest.h>
#import "GCDWebServer.h"
#import "GCDWebServerFunctions.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebDAVServer.h"
#import "GCDWebUploader.h"

#pragma clang diagnostic ignored "-Weverything"

@interface GCDWebServerTests : XCTestCase
@end

@implementation GCDWebServerTests

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

@end
