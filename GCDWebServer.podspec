# CocoaPods is NOT supported for this Mobile Locker fork.
# Use Swift Package Manager with:
#   https://github.com/mobilelocker/GCDWebServer.git
#
# This podspec is retained only so accidental `pod install` fails loudly
# with a clear message rather than pulling the stale swisspol 3.5.4 metadata.

Pod::Spec.new do |s|
  s.name     = 'GCDWebServer'
  s.version  = '4.0.1'
  s.author   = { 'Mobile Locker' => 'mark@mobilelocker.com' }
  s.license  = { :type => 'BSD', :file => 'LICENSE' }
  s.homepage = 'https://github.com/mobilelocker/GCDWebServer'
  s.summary  = 'DEPRECATED for CocoaPods — use SPM from GitHub (iOS 18+ Mobile Locker fork)'
  s.source   = { :git => 'https://github.com/mobilelocker/GCDWebServer.git', :tag => s.version.to_s }
  s.ios.deployment_target = '18.0'
  s.requires_arc = true

  # Force CocoaPods consumers to migrate to SPM.
  s.prepare_command = <<-CMD
    echo "error: GCDWebServer CocoaPods is unsupported in the Mobile Locker fork." >&2
    echo "error: Use Swift Package Manager: https://github.com/mobilelocker/GCDWebServer.git" >&2
    exit 1
  CMD

  s.source_files = 'GCDWebServer/**/*.{h,m}'
end
