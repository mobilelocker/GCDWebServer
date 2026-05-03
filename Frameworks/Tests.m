#import <GCDWebServers/GCDWebServers.h>
#import <XCTest/XCTest.h>

#pragma clang diagnostic ignored "-Weverything"  // Prevent "messaging to unqualified id" warnings

@interface Tests : XCTestCase
@end

@implementation Tests

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
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/bar//"), @"foo/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/./bar"), @"foo/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/bar/."), @"foo/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/../bar"), @"bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/../bar"), @"/bar");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/.."), @"/");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/.."), @"/");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"."), @"");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@".."), @"");
  XCTAssertEqualObjects(GCDWebServerNormalizePath(@"../.."), @"");
}

// Tests for issue #4: GCDWebServerEscapeURLString / GCDWebServerUnescapeURLString
- (void)testURLEscaping {
  // Characters that must be escaped per the documented contract (:@/?&=+)
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@":"), @"%3A");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"@"), @"%40");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"/"), @"%2F");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"?"), @"%3F");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"&"), @"%26");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"="), @"%3D");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"+"), @"%2B");

  // Unreserved characters must NOT be escaped (RFC 3986 §2.3)
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"abc"), @"abc");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"ABC"), @"ABC");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"123"), @"123");
  XCTAssertEqualObjects(GCDWebServerEscapeURLString(@"-_.~"), @"-_.~");

  // Non-ASCII characters must be percent-encoded as UTF-8 bytes
  NSString* escaped = GCDWebServerEscapeURLString(@"café");
  XCTAssertNotNil(escaped);
  XCTAssertFalse([escaped containsString:@"é"]);
  XCTAssertTrue([escaped hasPrefix:@"caf"]);

  // Typical query parameter value with multiple special characters
  NSString* value = @"hello world+foo=bar&baz";
  NSString* encodedValue = GCDWebServerEscapeURLString(value);
  XCTAssertFalse([encodedValue containsString:@" "]);
  XCTAssertFalse([encodedValue containsString:@"+"]);
  XCTAssertFalse([encodedValue containsString:@"="]);
  XCTAssertFalse([encodedValue containsString:@"&"]);
}

- (void)testURLUnescaping {
  // Basic percent sequences
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%3A"), @":");
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%40"), @"@");
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%2F"), @"/");
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%3F"), @"?");
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%26"), @"&");
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%3D"), @"=");
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"%2B"), @"+");

  // Strings with no encoding should pass through unchanged
  XCTAssertEqualObjects(GCDWebServerUnescapeURLString(@"hello"), @"hello");

  // Roundtrip: escape then unescape must recover original
  NSString* original = @"hello world: foo/bar?baz=qux&quux+corge";
  NSString* roundtripped = GCDWebServerUnescapeURLString(GCDWebServerEscapeURLString(original));
  XCTAssertEqualObjects(roundtripped, original);
}

// Tests for issue #6: GCDWebServerSanitizeHeaderValue strips CRLF characters
- (void)testHeaderSanitization {
  // Clean values must pass through unchanged
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"application/json"), @"application/json");
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"Basic realm=\"My App\""), @"Basic realm=\"My App\"");
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@""), @"");

  // CR alone must be stripped
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"foo\rbar"), @"foobar");

  // LF alone must be stripped
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"foo\nbar"), @"foobar");

  // CRLF sequence must be stripped (classic header injection vector)
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"foo\r\nX-Injected: evil"), @"fooX-Injected: evil");

  // Multiple injections in one value
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"a\r\nb\r\nc"), @"abc");

  // Injection at start and end
  XCTAssertEqualObjects(GCDWebServerSanitizeHeaderValue(@"\r\nvalue\r\n"), @"value");
}

// Tests for issue #2: chunked transfer encoding parses correctly via live server.
// This exercises _ScanHexNumber (the function whose VLA was replaced) end-to-end.
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

  // Send the body using chunked transfer encoding by omitting Content-Length
  NSData* body = [@"Hello, chunked world!" dataUsingEncoding:NSUTF8StringEncoding];
  req.HTTPBody = body;
  [req setValue:@"chunked" forHTTPHeaderField:@"Transfer-Encoding"];
  [req setValue:nil forHTTPHeaderField:@"Content-Length"];

  XCTestExpectation* done = [self expectationWithDescription:@"request complete"];
  NSURLSession* session = [NSURLSession sharedSession];
  [[session dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    XCTAssertNil(error, @"Request error: %@", error);
    XCTAssertEqual([(NSHTTPURLResponse*)response statusCode], 200);
    [done fulfill];
  }] resume];

  [self waitForExpectationsWithTimeout:5.0 handler:nil];

  XCTAssertEqualObjects(receivedBody, body, @"Server received wrong body via chunked transfer");

  [server stop];
}

@end
