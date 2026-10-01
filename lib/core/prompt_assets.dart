/// Pemuatan template prompt dari Flutter asset.
///
/// Dipisah dari `prompt.dart` supaya logika substitusi tetap Dart murni dan
/// bisa dipakai perkakas CLI maupun tes tanpa binding Flutter.
library;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'prompt.dart';

Future<String> loadPromptTemplate({AssetBundle? bundle}) {
  return (bundle ?? rootBundle).loadString(promptAssetPath);
}
