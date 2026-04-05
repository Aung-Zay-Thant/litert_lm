import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Securely stores the Hugging Face token and onboarding state.
class TokenStore {
  const TokenStore({
    String tokenKey = 'hugging_face_token',
    String onboardingKey = 'onboarding_complete',
  }) : _tokenKey = tokenKey,
       _onboardingKey = onboardingKey;

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final String _tokenKey;
  final String _onboardingKey;

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<void> writeToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<bool> readOnboardingComplete() async =>
      (await _storage.read(key: _onboardingKey)) == 'true';

  Future<void> writeOnboardingComplete(bool value) =>
      _storage.write(key: _onboardingKey, value: value.toString());
}
