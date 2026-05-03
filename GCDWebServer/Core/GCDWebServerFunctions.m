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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#else
#import <CoreServices/CoreServices.h>
#endif
#import <CommonCrypto/CommonDigest.h>

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <netinet/in.h>

#import "GCDWebServerPrivate.h"

static NSDateFormatter* _dateFormatterRFC822 = nil;
static NSDateFormatter* _dateFormatterISO8601 = nil;
static dispatch_queue_t _dateFormatterQueue = NULL;

// TODO: Handle RFC 850 and ANSI C's asctime() format
void GCDWebServerInitializeFunctions() {
  GWS_DCHECK([NSThread isMainThread]);  // NSDateFormatter should be initialized on main thread
  if (_dateFormatterRFC822 == nil) {
    _dateFormatterRFC822 = [[NSDateFormatter alloc] init];
    _dateFormatterRFC822.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    _dateFormatterRFC822.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
    _dateFormatterRFC822.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    GWS_DCHECK(_dateFormatterRFC822);
  }
  if (_dateFormatterISO8601 == nil) {
    _dateFormatterISO8601 = [[NSDateFormatter alloc] init];
    _dateFormatterISO8601.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    _dateFormatterISO8601.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'+00:00'";
    _dateFormatterISO8601.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    GWS_DCHECK(_dateFormatterISO8601);
  }
  if (_dateFormatterQueue == NULL) {
    _dateFormatterQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    GWS_DCHECK(_dateFormatterQueue);
  }
}

NSString* GCDWebServerNormalizeHeaderValue(NSString* value) {
  if (value) {
    NSRange range = [value rangeOfString:@";"];  // Assume part before ";" separator is case-insensitive
    if (range.location != NSNotFound) {
      value = [[[value substringToIndex:range.location] lowercaseString] stringByAppendingString:[value substringFromIndex:range.location]];
    } else {
      value = [value lowercaseString];
    }
  }
  return value;
}

NSString* GCDWebServerTruncateHeaderValue(NSString* value) {
  if (value) {
    NSRange range = [value rangeOfString:@";"];
    if (range.location != NSNotFound) {
      return [value substringToIndex:range.location];
    }
  }
  return value;
}

NSString* GCDWebServerExtractHeaderValueParameter(NSString* value, NSString* name) {
  NSString* parameter = nil;
  if (value) {
    NSScanner* scanner = [[NSScanner alloc] initWithString:value];
    [scanner setCaseSensitive:NO];  // Assume parameter names are case-insensitive
    NSString* string = [NSString stringWithFormat:@"%@=", name];
    if ([scanner scanUpToString:string intoString:NULL]) {
      [scanner scanString:string intoString:NULL];
      if ([scanner scanString:@"\"" intoString:NULL]) {
        [scanner scanUpToString:@"\"" intoString:&parameter];
      } else {
        [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&parameter];
      }
    }
  }
  return parameter;
}

// http://www.w3schools.com/tags/ref_charactersets.asp
NSStringEncoding GCDWebServerStringEncodingFromCharset(NSString* charset) {
  NSStringEncoding encoding = kCFStringEncodingInvalidId;
  if (charset) {
    encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)charset));
  }
  return (encoding != kCFStringEncodingInvalidId ? encoding : NSUTF8StringEncoding);
}

NSString* GCDWebServerFormatRFC822(NSDate* date) {
  __block NSString* string;
  dispatch_sync(_dateFormatterQueue, ^{
    string = [_dateFormatterRFC822 stringFromDate:date];
  });
  return string;
}

NSDate* GCDWebServerParseRFC822(NSString* string) {
  __block NSDate* date;
  dispatch_sync(_dateFormatterQueue, ^{
    date = [_dateFormatterRFC822 dateFromString:string];
  });
  return date;
}

NSString* GCDWebServerFormatISO8601(NSDate* date) {
  __block NSString* string;
  dispatch_sync(_dateFormatterQueue, ^{
    string = [_dateFormatterISO8601 stringFromDate:date];
  });
  return string;
}

NSDate* GCDWebServerParseISO8601(NSString* string) {
  __block NSDate* date;
  dispatch_sync(_dateFormatterQueue, ^{
    date = [_dateFormatterISO8601 dateFromString:string];
  });
  return date;
}

BOOL GCDWebServerIsTextContentType(NSString* type) {
  return ([type hasPrefix:@"text/"] || [type hasPrefix:@"application/json"] || [type hasPrefix:@"application/xml"]);
}

NSString* GCDWebServerDescribeData(NSData* data, NSString* type) {
  if (GCDWebServerIsTextContentType(type)) {
    NSString* charset = GCDWebServerExtractHeaderValueParameter(type, @"charset");
    NSString* string = [[NSString alloc] initWithData:data encoding:GCDWebServerStringEncodingFromCharset(charset)];
    if (string) {
      return string;
    }
  }
  return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
}

NSString* GCDWebServerGetMimeTypeForExtension(NSString* extension, NSDictionary<NSString*, NSString*>* overrides) {
  NSDictionary* builtInOverrides = @{@"css" : @"text/css"};
  NSString* mimeType = nil;
  extension = [extension lowercaseString];
  if (extension.length) {
    mimeType = [overrides objectForKey:extension];
    if (mimeType == nil) {
      mimeType = [builtInOverrides objectForKey:extension];
    }
    if (mimeType == nil) {
#if TARGET_OS_IPHONE
      mimeType = [UTType typeWithFilenameExtension:extension].preferredMIMEType;
#else
      // macOS test-runner path — remove when Mac Xcode target is retired
      CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)extension, NULL);
      if (uti) {
        mimeType = CFBridgingRelease(UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType));
        CFRelease(uti);
      }
#endif
    }
  }
  return mimeType ? mimeType : kGCDWebServerDefaultMimeType;
}

NSString* GCDWebServerEscapeURLString(NSString* string) {
  NSMutableCharacterSet* allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
  [allowed removeCharactersInString:@":@/?&=+"];
  return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

NSString* GCDWebServerUnescapeURLString(NSString* string) {
  return [string stringByRemovingPercentEncoding];
}

NSDictionary<NSString*, NSString*>* GCDWebServerParseURLEncodedForm(NSString* form) {
  NSMutableDictionary* parameters = [NSMutableDictionary dictionary];
  NSScanner* scanner = [[NSScanner alloc] initWithString:form];
  [scanner setCharactersToBeSkipped:nil];
  while (1) {
    NSString* key = nil;
    if (![scanner scanUpToString:@"=" intoString:&key] || [scanner isAtEnd]) {
      break;
    }
    [scanner scanString:@"=" intoString:NULL];

    NSString* value = nil;
    [scanner scanUpToString:@"&" intoString:&value];
    if (value == nil) {
      value = @"";
    }

    key = [key stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    NSString* unescapedKey = key ? GCDWebServerUnescapeURLString(key) : nil;
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    NSString* unescapedValue = value ? GCDWebServerUnescapeURLString(value) : nil;
    if (unescapedKey && unescapedValue) {
      [parameters setObject:unescapedValue forKey:unescapedKey];
    } else {
      GWS_LOG_WARNING(@"Failed parsing URL encoded form for key \"%@\" and value \"%@\"", key, value);
      GWS_DNOT_REACHED();
    }

    if ([scanner isAtEnd]) {
      break;
    }
    [scanner scanString:@"&" intoString:NULL];
  }
  return parameters;
}

NSString* GCDWebServerStringFromSockAddr(const struct sockaddr* addr, BOOL includeService) {
  char hostBuffer[NI_MAXHOST];
  char serviceBuffer[NI_MAXSERV];
  if (getnameinfo(addr, addr->sa_len, hostBuffer, sizeof(hostBuffer), serviceBuffer, sizeof(serviceBuffer), NI_NUMERICHOST | NI_NUMERICSERV | NI_NOFQDN) != 0) {
    GWS_DCHECK(NO);  // Should not happen for a numeric conversion
    // Fall back to inet_ntop for basic IPv4/IPv6 formatting without requiring getnameinfo
    const void* addrBytes = NULL;
    if (addr->sa_family == AF_INET) {
      addrBytes = &((const struct sockaddr_in*)addr)->sin_addr;
    } else if (addr->sa_family == AF_INET6) {
      addrBytes = &((const struct sockaddr_in6*)addr)->sin6_addr;
    }
    if (addrBytes && inet_ntop(addr->sa_family, addrBytes, hostBuffer, sizeof(hostBuffer))) {
      snprintf(serviceBuffer, sizeof(serviceBuffer), "0");
    } else {
      return @"unknown";
    }
  }
  return includeService ? [NSString stringWithFormat:@"%s:%s", hostBuffer, serviceBuffer] : (NSString*)[NSString stringWithUTF8String:hostBuffer];
}

NSString* GCDWebServerGetPrimaryIPAddress(BOOL useIPv6) {
  NSString* address = nil;
#if TARGET_IPHONE_SIMULATOR
  // In the iOS Simulator, check en0 (Ethernet) and en1 (WiFi) since
  // SystemConfiguration is not reliable in simulator environments.
  const char* const simulatorInterfaces[] = {"en0", "en1", NULL};
#else
  const char* primaryInterface = "en0";  // WiFi interface on iOS device
#endif
  struct ifaddrs* list;
  if (getifaddrs(&list) >= 0) {
    for (struct ifaddrs* ifap = list; ifap; ifap = ifap->ifa_next) {
#if TARGET_IPHONE_SIMULATOR
      BOOL matchedInterface = NO;
      for (int i = 0; simulatorInterfaces[i] != NULL; i++) {
        if (strcmp(ifap->ifa_name, simulatorInterfaces[i]) == 0) { matchedInterface = YES; break; }
      }
      if (!matchedInterface)
#else
      if (strcmp(ifap->ifa_name, primaryInterface))
#endif
      {
        continue;
      }
      if ((ifap->ifa_flags & IFF_UP) && ((!useIPv6 && (ifap->ifa_addr->sa_family == AF_INET)) || (useIPv6 && (ifap->ifa_addr->sa_family == AF_INET6)))) {
        address = GCDWebServerStringFromSockAddr(ifap->ifa_addr, NO);
        break;
      }
    }
    freeifaddrs(list);
  }
  return address;
}

NSString* GCDWebServerComputeMD5Digest(NSString* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  const char* string = [[[NSString alloc] initWithFormat:format arguments:arguments] UTF8String];
  va_end(arguments);
  unsigned char md5[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_MD5(string, (CC_LONG)strlen(string), md5);
#pragma clang diagnostic pop
  char buffer[2 * CC_MD5_DIGEST_LENGTH + 1];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; ++i) {
    unsigned char byte = md5[i];
    unsigned char byteHi = (byte & 0xF0) >> 4;
    buffer[2 * i + 0] = byteHi >= 10 ? 'a' + byteHi - 10 : '0' + byteHi;
    unsigned char byteLo = byte & 0x0F;
    buffer[2 * i + 1] = byteLo >= 10 ? 'a' + byteLo - 10 : '0' + byteLo;
  }
  buffer[2 * CC_MD5_DIGEST_LENGTH] = 0;
  return (NSString*)[NSString stringWithUTF8String:buffer];
}

NSString* GCDWebServerNormalizePath(NSString* path) {
  NSMutableArray* components = [[NSMutableArray alloc] init];
  for (NSString* component in [path componentsSeparatedByString:@"/"]) {
    if ([component isEqualToString:@".."]) {
      [components removeLastObject];
    } else if (component.length && ![component isEqualToString:@"."]) {
      [components addObject:component];
    }
  }
  if (path.length && ([path characterAtIndex:0] == '/')) {
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];  // Preserve initial slash
  }
  return [components componentsJoinedByString:@"/"];
}

NSString* GCDWebServerSanitizeHeaderValue(NSString* value) {
  NSCharacterSet* crlf = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
  NSArray<NSString*>* components = [value componentsSeparatedByCharactersInSet:crlf];
  return [components componentsJoinedByString:@""];
}
