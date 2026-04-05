# litert_lm

Flutter plugin for on-device LLM inference using [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM). Run Gemma 4 and other models locally on iOS and Android — no cloud required.

## Features

- Streaming text generation with token-by-token output
- Multimodal prompts (text + image)
- System prompt for persona/behavior control
- Cancel generation mid-stream
- Conversation context with reset
- Model download from Hugging Face with resume support
- Secure token storage (iOS Keychain / Android EncryptedSharedPreferences)

## Platform Support

| Platform | Engine | Status |
|----------|--------|--------|
| iOS 17+  | Native C API via `dlopen` | Stable |
| Android 8+ (API 26) | Official Kotlin SDK (`litertlm-android`) | Stable |

## Quick Start

### 1. Add dependency

```yaml
dependencies:
  litert_lm:
    git:
      url: https://github.com/user/litert_lm
```

### 2. Download a model

```dart
import 'package:litert_lm/litert_lm.dart';

final downloader = ModelDownloader.gemma4E2B();

// Validate Hugging Face token
await downloader.validateToken('hf_...');

// Download with progress
final modelPath = await downloader.download(
  token: 'hf_...',
  onProgress: (received, total) {
    print('${(received / total * 100).toInt()}%');
  },
);
```

### 3. Chat with streaming

```dart
final engine = LiteRtLmEngine();

// Load model with system prompt
await engine.prepare(
  modelPath: modelPath,
  systemPrompt: 'You are a helpful assistant.',
);

// Stream response token by token
await for (final chunk in engine.generateStream(prompt: 'What is Flutter?')) {
  stdout.write(chunk);
}
```

### 4. Image prompts (multimodal)

```dart
await for (final chunk in engine.generateStream(
  prompt: 'What do you see in this image?',
  imagePath: '/path/to/photo.jpg',
)) {
  stdout.write(chunk);
}
```

### 5. Cancel and reset

```dart
// Stop generation mid-stream
await engine.cancel();

// Clear conversation context
await engine.resetConversation();
```

## iOS Setup

The LiteRT-LM runtime libraries must be included in your iOS app:

1. Download the LiteRT-LM xcframework and dylibs from the [LiteRT-LM releases](https://github.com/google-ai-edge/LiteRT-LM/releases)
2. Add `LiteRTLMEngine.xcframework` to your Xcode project
3. Add `libengine_cpu_shared.dylib` and `libGemmaModelConstraintProvider.dylib` to the app's Frameworks

## Android Setup

No extra setup needed. The `litertlm-android` SDK is pulled automatically from Google Maven.

For GPU acceleration, add to your `AndroidManifest.xml` inside `<application>`:
```xml
<uses-native-library android:name="libOpenCL.so" android:required="false"/>
```

## API Reference

### LiteRtLmEngine

| Method | Description |
|--------|-------------|
| `prepare(modelPath, systemPrompt?)` | Load a model and set system prompt |
| `generateStream(prompt, imagePath?)` | Stream a response as `Stream<String>` |
| `cancel()` | Stop generation mid-stream |
| `resetConversation()` | Clear conversation context |

### ModelDownloader

| Method | Description |
|--------|-------------|
| `ModelDownloader.gemma4E2B()` | Pre-configured for Gemma 4 E2B |
| `validateToken(token)` | Validate a Hugging Face token |
| `download(token, onProgress)` | Download model with resume support |
| `findInstalledModelPath()` | Check if model is already downloaded |
| `delete()` | Remove downloaded model |

### TokenStore

| Method | Description |
|--------|-------------|
| `readToken()` / `writeToken(token)` | Secure token storage |
| `readOnboardingComplete()` / `writeOnboardingComplete(value)` | Onboarding flag |

## License

MIT
