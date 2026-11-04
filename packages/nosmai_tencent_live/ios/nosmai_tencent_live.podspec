Pod::Spec.new do |s|
  s.name             = 'nosmai_tencent_live'
  s.version          = '1.0.0'
  s.summary          = 'Livestream Nosmai-processed camera video through Tencent RTC.'
  s.description      = <<-DESC
Forwards Nosmai's processed camera frames into Tencent RTC custom video capture,
so Flutter apps can livestream Nosmai effects without native code.
                       DESC
  s.homepage         = 'https://github.com/HashirYamin-dev/nosmai_tencent_livestreaming'
  s.license          = { :type => 'Proprietary', :text => 'Nosmai and Tencent RTC are governed by their own licenses.' }
  s.author           = { 'Nosmai' => 'admin@nosmai.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/NosmaiTencentLivePlugin.h'
  s.resource_bundles = {
    'nosmai_tencent_live_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  s.dependency 'Flutter'
  # Versions are pinned by nosmai_effects_sdk and tencent_rtc_sdk.
  s.dependency 'nosmai_effects_sdk'
  s.dependency 'TXLiteAVSDK_Professional'

  s.platform = :ios, '15.0'
  # TXLiteAVSDK_Professional is a static framework.
  s.static_framework = true
  s.frameworks = 'AVFoundation', 'CoreVideo', 'QuartzCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  # tencent_rtc_sdk resolves Tencent's C API through Dart FFI at runtime, so
  # release builds must keep global symbols in the app binary.
  s.user_target_xcconfig = {
    'STRIP_STYLE' => 'non-global'
  }
end
