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
  s.preserve_paths   = 'LiteRTLM/libs/*.dylib'

  s.dependency 'Flutter'
  s.library = 'c++'
  s.script_phase = {
    :name => 'Embed LiteRTLM dylibs',
    :execution_position => :after_compile,
    :input_files => [
      '${PODS_TARGET_SRCROOT}/LiteRTLM/libs/libengine_cpu_ios_arm64.dylib',
      '${PODS_TARGET_SRCROOT}/LiteRTLM/libs/libengine_cpu_ios_sim_arm64.dylib',
      '${PODS_TARGET_SRCROOT}/LiteRTLM/libs/libGemmaModelConstraintProvider_ios_arm64.dylib',
      '${PODS_TARGET_SRCROOT}/LiteRTLM/libs/libGemmaModelConstraintProvider_ios_sim_arm64.dylib',
    ],
    :output_files => [
      '${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/libengine_cpu_shared.dylib',
      '${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/libGemmaModelConstraintProvider.dylib',
    ],
    :script => <<-'SCRIPT'
set -e
mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
rm -f "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libengine_cpu_shared.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libGemmaModelConstraintProvider.dylib"
if [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
  install -m 755 "$PODS_TARGET_SRCROOT/LiteRTLM/libs/libengine_cpu_ios_sim_arm64.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libengine_cpu_shared.dylib"
  install -m 755 "$PODS_TARGET_SRCROOT/LiteRTLM/libs/libGemmaModelConstraintProvider_ios_sim_arm64.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libGemmaModelConstraintProvider.dylib"
else
  install -m 755 "$PODS_TARGET_SRCROOT/LiteRTLM/libs/libengine_cpu_ios_arm64.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libengine_cpu_shared.dylib"
  install -m 755 "$PODS_TARGET_SRCROOT/LiteRTLM/libs/libGemmaModelConstraintProvider_ios_arm64.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libGemmaModelConstraintProvider.dylib"
  if [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libengine_cpu_shared.dylib"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libGemmaModelConstraintProvider.dylib"
  fi
fi
SCRIPT
  }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
end
