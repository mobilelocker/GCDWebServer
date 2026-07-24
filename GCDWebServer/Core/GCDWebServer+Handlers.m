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

#import "GCDWebServerPrivate.h"

// GCD-23: extracted from GCDWebServer.m — route registration helpers

@implementation GCDWebServer (Handlers)

- (void)addDefaultHandlerForMethod:(NSString*)method requestClass:(Class)aClass processBlock:(GCDWebServerProcessBlock)block {
  [self addDefaultHandlerForMethod:method
                      requestClass:aClass
                 asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
                   completionBlock(block(request));
                 }];
}

- (void)addDefaultHandlerForMethod:(NSString*)method requestClass:(Class)aClass asyncProcessBlock:(GCDWebServerAsyncProcessBlock)block {
  [self
      addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* requestMethod, NSURL* requestURL, NSDictionary<NSString*, NSString*>* requestHeaders, NSString* urlPath, NSDictionary<NSString*, NSString*>* urlQuery) {
        if (![requestMethod isEqualToString:method]) {
          return nil;
        }
        return [(GCDWebServerRequest*)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
      }
             asyncProcessBlock:block];
}

- (void)addHandlerForMethod:(NSString*)method path:(NSString*)path requestClass:(Class)aClass processBlock:(GCDWebServerProcessBlock)block {
  [self addHandlerForMethod:method
                       path:path
               requestClass:aClass
          asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
            completionBlock(block(request));
          }];
}

- (void)addHandlerForMethod:(NSString*)method path:(NSString*)path requestClass:(Class)aClass asyncProcessBlock:(GCDWebServerAsyncProcessBlock)block {
  if ([path hasPrefix:@"/"] && [aClass isSubclassOfClass:[GCDWebServerRequest class]]) {
    [self
        addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* requestMethod, NSURL* requestURL, NSDictionary<NSString*, NSString*>* requestHeaders, NSString* urlPath, NSDictionary<NSString*, NSString*>* urlQuery) {
          if (![requestMethod isEqualToString:method]) {
            return nil;
          }
          if ([urlPath caseInsensitiveCompare:path] != NSOrderedSame) {
            return nil;
          }
          return [(GCDWebServerRequest*)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
        }
               asyncProcessBlock:block];
  } else {
    GWS_DNOT_REACHED();
  }
}

- (void)addHandlerForMethod:(NSString*)method pathRegex:(NSString*)regex requestClass:(Class)aClass processBlock:(GCDWebServerProcessBlock)block {
  [self addHandlerForMethod:method
                  pathRegex:regex
               requestClass:aClass
          asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
            completionBlock(block(request));
          }];
}

- (void)addHandlerForMethod:(NSString*)method pathRegex:(NSString*)regex requestClass:(Class)aClass asyncProcessBlock:(GCDWebServerAsyncProcessBlock)block {
  NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:regex options:NSRegularExpressionCaseInsensitive error:NULL];
  if (expression && [aClass isSubclassOfClass:[GCDWebServerRequest class]]) {
    [self
        addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* requestMethod, NSURL* requestURL, NSDictionary<NSString*, NSString*>* requestHeaders, NSString* urlPath, NSDictionary<NSString*, NSString*>* urlQuery) {
          if (![requestMethod isEqualToString:method]) {
            return nil;
          }

          NSArray* matches = [expression matchesInString:urlPath options:0 range:NSMakeRange(0, urlPath.length)];
          if (matches.count == 0) {
            return nil;
          }

          NSMutableArray* captures = [NSMutableArray array];
          for (NSTextCheckingResult* result in matches) {
            // Start at 1; index 0 is the whole string
            for (NSUInteger i = 1; i < result.numberOfRanges; i++) {
              NSRange range = [result rangeAtIndex:i];
              // range is {NSNotFound, 0} "if one of the capture groups did not participate in this particular match"
              // see discussion in -[NSRegularExpression firstMatchInString:options:range:]
              if (range.location != NSNotFound) {
                [captures addObject:[urlPath substringWithRange:range]];
              }
            }
          }

          GCDWebServerRequest* request = [(GCDWebServerRequest*)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
          [request setAttribute:captures forKey:GCDWebServerRequestAttribute_RegexCaptures];
          return request;
        }
               asyncProcessBlock:block];
  } else {
    GWS_DNOT_REACHED();
  }
}

@end

@implementation GCDWebServer (GETHandlers)

- (void)addGETHandlerForPath:(NSString*)path staticData:(NSData*)staticData contentType:(NSString*)contentType cacheAge:(NSUInteger)cacheAge {
  [self addHandlerForMethod:@"GET"
                       path:path
               requestClass:[GCDWebServerRequest class]
               processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                 GCDWebServerResponse* response = [GCDWebServerDataResponse responseWithData:staticData contentType:contentType];
                 response.cacheControlMaxAge = cacheAge;
                 return response;
               }];
}

- (void)addGETHandlerForPath:(NSString*)path filePath:(NSString*)filePath isAttachment:(BOOL)isAttachment cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests {
  [self addHandlerForMethod:@"GET"
                       path:path
               requestClass:[GCDWebServerRequest class]
               processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                 GCDWebServerResponse* response = nil;
                 if (allowRangeRequests) {
                   response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange isAttachment:isAttachment];
                   [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                 } else {
                   response = [GCDWebServerFileResponse responseWithFile:filePath isAttachment:isAttachment];
                 }
                 response.cacheControlMaxAge = cacheAge;
                 return response;
               }];
}

- (GCDWebServerResponse*)_responseWithContentsOfDirectory:(NSString*)path {
  NSArray* contents = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
  if (contents == nil) {
    return nil;
  }
  NSMutableString* html = [NSMutableString string];
  [html appendString:@"<!DOCTYPE html>\n"];
  [html appendString:@"<html><head><meta charset=\"utf-8\"></head><body>\n"];
  [html appendString:@"<ul>\n"];
  for (NSString* entry in contents) {
    if (![entry hasPrefix:@"."]) {
      NSString* type = [[[NSFileManager defaultManager] attributesOfItemAtPath:[path stringByAppendingPathComponent:entry] error:NULL] objectForKey:NSFileType];
      GWS_DCHECK(type);
      NSString* escapedFile = [entry stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
      GWS_DCHECK(escapedFile);
      if ([type isEqualToString:NSFileTypeRegular]) {
        [html appendFormat:@"<li><a href=\"%@\">%@</a></li>\n", escapedFile, entry];
      } else if ([type isEqualToString:NSFileTypeDirectory]) {
        [html appendFormat:@"<li><a href=\"%@/\">%@/</a></li>\n", escapedFile, entry];
      }
    }
  }
  [html appendString:@"</ul>\n"];
  [html appendString:@"</body></html>\n"];
  return [GCDWebServerDataResponse responseWithHTML:html];
}

- (void)addGETHandlerForBasePath:(NSString*)basePath directoryPath:(NSString*)directoryPath indexFilename:(NSString*)indexFilename cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests {
  if ([basePath hasPrefix:@"/"] && [basePath hasSuffix:@"/"]) {
    GCDWebServer* __unsafe_unretained server = self;
    [self
        addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* requestMethod, NSURL* requestURL, NSDictionary<NSString*, NSString*>* requestHeaders, NSString* urlPath, NSDictionary<NSString*, NSString*>* urlQuery) {
          if (![requestMethod isEqualToString:@"GET"]) {
            return nil;
          }
          if (![urlPath hasPrefix:basePath]) {
            return nil;
          }
          return [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
        }
        processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
          GCDWebServerResponse* response = nil;
          NSString* filePath = [directoryPath stringByAppendingPathComponent:GCDWebServerNormalizePath([request.path substringFromIndex:basePath.length])];
          NSString* fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];
          if (fileType) {
            if ([fileType isEqualToString:NSFileTypeDirectory]) {
              if (indexFilename) {
                NSString* indexPath = [filePath stringByAppendingPathComponent:indexFilename];
                NSString* indexType = [[[NSFileManager defaultManager] attributesOfItemAtPath:indexPath error:NULL] fileType];
                if ([indexType isEqualToString:NSFileTypeRegular]) {
                  return [GCDWebServerFileResponse responseWithFile:indexPath];
                }
              }
              response = [server _responseWithContentsOfDirectory:filePath];
            } else if ([fileType isEqualToString:NSFileTypeRegular]) {
              if (allowRangeRequests) {
                response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
              } else {
                response = [GCDWebServerFileResponse responseWithFile:filePath];
              }
            }
          }
          if (response) {
            response.cacheControlMaxAge = cacheAge;
          } else {
            response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
          }
          return response;
        }];
  } else {
    GWS_DNOT_REACHED();
  }
}

@end
