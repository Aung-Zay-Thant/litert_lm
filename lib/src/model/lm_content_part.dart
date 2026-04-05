sealed class LmContentPart {
  const LmContentPart();
}

final class LmTextPart extends LmContentPart {
  const LmTextPart(this.text);

  final String text;
}

final class LmImagePathPart extends LmContentPart {
  const LmImagePathPart(this.path);

  final String path;
}
