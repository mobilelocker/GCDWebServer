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

#import <unistd.h>

#import "GCDWebServerPrivate.h"

// GCD-23: built-in logging facility + Logging category (extracted from GCDWebServer.m)

#if defined(__GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__)
#if DEBUG
GCDWebServerLoggingLevel GCDWebServerLogLevel = kGCDWebServerLoggingLevel_Debug;
#else
GCDWebServerLoggingLevel GCDWebServerLogLevel = kGCDWebServerLoggingLevel_Info;
#endif
#endif

#ifdef __GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__

static GCDWebServerBuiltInLoggerBlock _builtInLoggerBlock;

void GCDWebServerLogMessage(GCDWebServerLoggingLevel level, NSString* format, ...) {
  static const char* levelNames[] = {"DEBUG", "VERBOSE", "INFO", "WARNING", "ERROR"};
  static int enableLogging = -1;
  if (enableLogging < 0) {
    enableLogging = (isatty(STDERR_FILENO) ? 1 : 0);
  }
  if (_builtInLoggerBlock || enableLogging) {
    va_list arguments;
    va_start(arguments, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (_builtInLoggerBlock) {
      _builtInLoggerBlock(level, message);
    } else {
      fprintf(stderr, "[%s] %s\n", levelNames[level], [message UTF8String]);
    }
  }
}

#endif

@implementation GCDWebServer (Logging)

+ (void)setLogLevel:(int)level {
#if defined(__GCDWEBSERVER_LOGGING_FACILITY_XLFACILITY__)
  [XLSharedFacility setMinLogLevel:level];
#elif defined(__GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__)
  GCDWebServerLogLevel = level;
#endif
}

+ (void)setBuiltInLogger:(GCDWebServerBuiltInLoggerBlock)block {
#if defined(__GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__)
  _builtInLoggerBlock = block;
#else
  GWS_DNOT_REACHED();  // Built-in logger must be enabled in order to override
#endif
}

- (void)logVerbose:(NSString*)format, ... {
  va_list arguments;
  va_start(arguments, format);
  GWS_LOG_VERBOSE(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
  va_end(arguments);
}

- (void)logInfo:(NSString*)format, ... {
  va_list arguments;
  va_start(arguments, format);
  GWS_LOG_INFO(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
  va_end(arguments);
}

- (void)logWarning:(NSString*)format, ... {
  va_list arguments;
  va_start(arguments, format);
  GWS_LOG_WARNING(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
  va_end(arguments);
}

- (void)logError:(NSString*)format, ... {
  va_list arguments;
  va_start(arguments, format);
  GWS_LOG_ERROR(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
  va_end(arguments);
}

@end
