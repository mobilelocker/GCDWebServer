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

#import <TargetConditionals.h>

#if TARGET_IPHONE_SIMULATOR
#define kDefaultPort 8080
#else
#define kDefaultPort 80
#endif

// GCD-23: extracted from GCDWebServer.m

@implementation GCDWebServer (Extensions)

- (NSURL*)serverURL {
  if (_source4) {
    NSString* ipAddress = _bindToLocalhost ? @"localhost" : GCDWebServerGetPrimaryIPAddress(NO);  // We can't really use IPv6 anyway as it doesn't work great with HTTP URLs in practice
    if (ipAddress) {
      if (_port != 80) {
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%i/", ipAddress, (int)_port]];
      } else {
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", ipAddress]];
      }
    }
  }
  return nil;
}

// GCD-5: Always loopback host for embedded WKWebView clients (independent of LAN IP).
- (NSURL*)localhostServerURL {
  if (_source4) {
    if (_port != 80) {
      return [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%i/", (int)_port]];
    }
    return [NSURL URLWithString:@"http://localhost/"];
  }
  return nil;
}

- (NSURL*)bonjourServerURL {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (_source4 && _resolutionService) {
    NSString* name = (__bridge NSString*)CFNetServiceGetTargetHost(_resolutionService);
    if (name.length) {
      name = [name substringToIndex:(name.length - 1)];  // Strip trailing period at end of domain
      if (_port != 80) {
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%i/", name, (int)_port]];
      } else {
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", name]];
      }
    }
  }
#pragma clang diagnostic pop
  return nil;
}

- (NSURL*)publicServerURL {
  if (_source4 && _dnsService && _dnsAddress && _dnsPort) {
    if (_dnsPort != 80) {
      return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%i/", _dnsAddress, (int)_dnsPort]];
    } else {
      return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", _dnsAddress]];
    }
  }
  return nil;
}

- (BOOL)start {
  return [self startWithPort:kDefaultPort bonjourName:@""];
}

- (BOOL)startWithPort:(NSUInteger)port bonjourName:(NSString*)name {
  NSMutableDictionary* options = [NSMutableDictionary dictionary];
  [options setObject:[NSNumber numberWithInteger:port] forKey:GCDWebServerOption_Port];
  [options setValue:name forKey:GCDWebServerOption_BonjourName];
  return [self startWithOptions:options error:NULL];
}

@end
