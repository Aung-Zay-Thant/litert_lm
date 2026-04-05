Pod::Spec.new do |s|
  s.name             = 'litert_lm'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for on-device LLM inference using LiteRT-LM.'
  s.homepage         = 'https://github.com/example/litert_lm'
  s.license          = { :type => 'MIT' }
  s.author           = { 'WoW' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,mm,swift}'
  s.platform         = :ios, '17.0'
  s.swift_version    = '5.0'

  s.dependency 'Flutter'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
end
