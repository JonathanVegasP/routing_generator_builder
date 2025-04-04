import 'package:analyzer/dart/constant/value.dart';

final class Routing {
  final Uri path;
  final String? name;
  final String page;
  final String isConst;
  final List<Routing> children = [];
  int skip = 0;
  Routing? topper;

  static Uri _createUri(String path) {
    final uri = Uri.parse(path);

    if (uri.hasEmptyPath) throw UnsupportedError('The "path" cannot be empty');

    return uri;
  }

  Routing({
    required DartObject object,
    required this.page,
    required this.isConst,
  }) : path = _createUri(object.getField('path')!.toStringValue()!),
       name = object.getField('name')!.toStringValue();

  void addChild(Routing child) {
    child.topper?.remove(child);
    child.topper = this;
    children.add(child);
  }

  void remove(Routing child) {
    children.remove(child);
  }
}
