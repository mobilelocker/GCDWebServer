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

// GCD-25: directory-style URL for index / entry fallback (matches PresentationWebServer).
static BOOL _GCDWebServerIsDirectoryStylePath(NSString* path) {
  return path.length == 0 || [path isEqualToString:@"/"] || [path hasSuffix:@"/"];
}

// GCD-25: MIME allowlist from Mobile Locker shouldGzip (MLI-1594).
static BOOL _GCDWebServerIsTextLikeMIMEType(NSString* contentType) {
  if (contentType.length == 0) {
    return NO;
  }
  NSString* mediaType = contentType;
  NSRange semi = [contentType rangeOfString:@";"];
  if (semi.location != NSNotFound) {
    mediaType = [contentType substringToIndex:semi.location];
  }
  mediaType = [[mediaType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
  if ([mediaType hasPrefix:@"text/"]) {
    return YES;
  }
  static NSSet<NSString*>* allow = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    allow = [NSSet setWithObjects:@"application/javascript", @"application/x-javascript", @"text/javascript", @"application/json", @"application/ld+json", @"application/xml", @"application/xhtml+xml", @"image/svg+xml", @"application/manifest+json", nil];
  });
  return [allow containsObject:mediaType];
}

static void _GCDWebServerApplyStaticGzipPolicy(GCDWebServerResponse* response, GCDWebServerStaticGzipPolicy gzipPolicy) {
  switch (gzipPolicy) {
    case GCDWebServerStaticGzipPolicyNever:
      response.gzipContentEncodingEnabled = NO;
      break;
    case GCDWebServerStaticGzipPolicyAlways:
      response.gzipContentEncodingEnabled = YES;
      break;
    case GCDWebServerStaticGzipPolicyTextLike:
    default:
      response.gzipContentEncodingEnabled = _GCDWebServerIsTextLikeMIMEType(response.contentType);
      break;
  }
}

// Map request path under urlBasePath to a document-root relative URL path starting with "/".
static NSString* _GCDWebServerRelativeURLPathForDocumentRoot(NSString* requestPath, NSString* urlBasePath) {
  if ([urlBasePath isEqualToString:@"/"]) {
    return requestPath.length ? requestPath : @"/";
  }
  NSString* base = urlBasePath;
  if (![base hasSuffix:@"/"]) {
    base = [base stringByAppendingString:@"/"];
  }
  if ([requestPath isEqualToString:[base substringToIndex:base.length - 1]] || [requestPath isEqualToString:base]) {
    return @"/";
  }
  if (![requestPath hasPrefix:base] && ![requestPath hasPrefix:[base substringToIndex:base.length - 1]]) {
    return nil;
  }
  NSString* suffix;
  if ([requestPath hasPrefix:base]) {
    suffix = [requestPath substringFromIndex:base.length];
  } else {
    // requestPath equals base without trailing slash handled above
    suffix = [requestPath substringFromIndex:MIN(requestPath.length, base.length - 1)];
    if ([suffix hasPrefix:@"/"]) {
      suffix = [suffix substringFromIndex:1];
    }
  }
  if (suffix.length == 0) {
    return @"/";
  }
  return [suffix hasPrefix:@"/"] ? suffix : [@"/" stringByAppendingString:suffix];
}

- (void)addGETHandlerForDocumentRoot:(NSString*)documentRoot
                         urlBasePath:(NSString*)urlBasePath
                       indexFilename:(NSString*)indexFilename
                   entryFallbackPath:(NSString*)entryFallbackPath
                            cacheAge:(NSUInteger)cacheAge
                          gzipPolicy:(GCDWebServerStaticGzipPolicy)gzipPolicy {
  if (documentRoot.length == 0 || ![urlBasePath hasPrefix:@"/"]) {
    GWS_DNOT_REACHED();
    return;
  }
  NSString* root = [documentRoot copy];
  NSString* basePath = [urlBasePath copy];
  NSString* indexName = indexFilename.length ? indexFilename : @"index.html";
  NSString* entryPath = [entryFallbackPath copy];
  BOOL useBuiltInIndex = [indexName isEqualToString:@"index.html"];

  [self
      addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* requestMethod, NSURL* requestURL, NSDictionary<NSString*, NSString*>* requestHeaders, NSString* urlPath, NSDictionary<NSString*, NSString*>* urlQuery) {
        if (![requestMethod isEqualToString:@"GET"]) {
          return nil;
        }
        if ([basePath isEqualToString:@"/"]) {
          // Catch-all for site root (LIFO: register before more-specific handlers).
        } else {
          NSString* baseNoSlash = [basePath hasSuffix:@"/"] ? [basePath substringToIndex:basePath.length - 1] : basePath;
          if (![urlPath isEqualToString:baseNoSlash] && ![urlPath hasPrefix:[baseNoSlash stringByAppendingString:@"/"]]) {
            return nil;
          }
        }
        return [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
      }
      processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
        NSString* relativeURLPath = _GCDWebServerRelativeURLPathForDocumentRoot(request.path, basePath);
        if (!relativeURLPath) {
          return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
        }

        GCDWebServerFileResponse* fileResponse = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                                             urlPath:relativeURLPath
                                                                                           byteRange:request.byteRange
                                                                                      allowIndexHTML:useBuiltInIndex
                                                                                   mimeTypeOverrides:nil];

        // Custom index file when not the built-in index.html name.
        if (!fileResponse && !useBuiltInIndex && _GCDWebServerIsDirectoryStylePath(relativeURLPath)) {
          NSString* dirPrefix = relativeURLPath;
          if ([dirPrefix hasSuffix:@"/"]) {
            dirPrefix = [dirPrefix substringToIndex:dirPrefix.length - 1];
          }
          if ([dirPrefix isEqualToString:@"/"]) {
            dirPrefix = @"";
          }
          NSString* indexRel = dirPrefix.length ? [dirPrefix stringByAppendingPathComponent:indexName] : [@"/" stringByAppendingString:indexName];
          if (![indexRel hasPrefix:@"/"]) {
            indexRel = [@"/" stringByAppendingString:indexRel];
          }
          fileResponse = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                     urlPath:indexRel
                                                                   byteRange:request.byteRange
                                                              allowIndexHTML:NO
                                                           mimeTypeOverrides:nil];
        }

        // Entry fallback (e.g. pack mainPath) for directory-style URLs only.
        if (!fileResponse && entryPath.length && _GCDWebServerIsDirectoryStylePath(relativeURLPath)) {
          NSString* entryRel = entryPath;
          if (![entryRel hasPrefix:@"/"]) {
            entryRel = [@"/" stringByAppendingString:entryRel];
          }
          fileResponse = [GCDWebServerFileResponse responseWithFileUnderRoot:root
                                                                     urlPath:entryRel
                                                                   byteRange:request.byteRange
                                                              allowIndexHTML:NO
                                                           mimeTypeOverrides:nil];
        }

        if (!fileResponse) {
          return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
        }

        fileResponse.cacheControlMaxAge = cacheAge;
        _GCDWebServerApplyStaticGzipPolicy(fileResponse, gzipPolicy);
        return fileResponse;
      }];
}

@end
