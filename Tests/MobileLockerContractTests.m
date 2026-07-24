// Mobile Locker contract tests — mirror PresentationWebServer usage of GCDWebServer.
// GCD-12 / GCD-13 / GCD-14

#import <XCTest/XCTest.h>
#import <zlib.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerRequest.h"

#pragma clang diagnostic ignored "-Weverything"

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
  NSData* body = [self ml_bodyFromRawHTTP:raw];
  XCTAssertNotEqualObjects(body, fileData);  // compressed on wire
  NSData* inflated = [self ml_gunzip:body];
  XCTAssertEqualObjects(inflated, fileData);

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
                   [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
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

@end
