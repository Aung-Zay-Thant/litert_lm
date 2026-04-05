import 'lm_content_part.dart';
import 'lm_role.dart';

final class LmMessage {
  const LmMessage({required this.role, required this.parts});

  factory LmMessage.text({required LmRole role, required String text}) {
    return LmMessage(role: role, parts: [LmTextPart(text)]);
  }

  factory LmMessage.userText(String text) =>
      LmMessage.text(role: LmRole.user, text: text);

  factory LmMessage.modelText(String text) =>
      LmMessage.text(role: LmRole.model, text: text);

  factory LmMessage.systemText(String text) =>
      LmMessage.text(role: LmRole.system, text: text);

  final LmRole role;
  final List<LmContentPart> parts;
}
