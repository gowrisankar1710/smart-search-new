/// Turns what people type ("woman wearing saree", "birds on stones") into the object /
/// scene labels the on-device image classifier produces ("sari", "people", "bird", "rocks").
library;

/// Words that don't name a thing in the picture.
const _stopWords = <String>{
  'a', 'an', 'the', 'in', 'on', 'at', 'of', 'with', 'and', 'or', 'by', 'for', 'to', 'near',
  'under', 'over', 'inside', 'my', 'some', 'is', 'are', 'like', 'look', 'looks', 'looking',
  'wear', 'wears', 'wearing', 'worn', 'showing', 'shows', 'having', 'has', 'full',
  'photo', 'photos', 'image', 'images', 'picture', 'pictures', 'pic', 'pics', 'img', 'jpg',
};

/// Everyday words → label words. Plurals are handled by [_singular] first.
const _aliases = <String, List<String>>{
  // clothing
  'saree': ['sari'], 'saris': ['sari'], 'sari': ['sari'],
  // "dress" covers dress-like garments; plain "clothes" covers anything worn.
  'dress': ['dress', 'gown', 'sari', 'kimono'], 'gown': ['gown', 'dress'],
  'clothe': ['clothing'], 'clothes': ['clothing'], 'clothing': ['clothing'], 'outfit': ['clothing'],
  'cloth': ['textile', 'clothing'], 'fabric': ['textile'], 'silk': ['textile'],
  'jewellery': ['jewelry'], 'jewelry': ['jewelry'], 'jewel': ['jewelry'],
  'tie': ['necktie'],
  // people
  'person': ['people'], 'people': ['people'], 'human': ['people'],
  'woman': ['people', 'adult'], 'women': ['people', 'adult'], 'lady': ['people', 'adult'],
  'ladies': ['people', 'adult'], 'man': ['people', 'adult'], 'men': ['people', 'adult'],
  'girl': ['people'], 'boy': ['people'], 'adult': ['adult'],
  'kid': ['child'], 'children': ['child'], 'child': ['child'], 'baby': ['baby'], 'babies': ['baby'],
  'crowd': ['crowd'], 'selfie': ['people'], 'portrait': ['people'], 'family': ['people'],
  // nature
  'stone': ['rocks'], 'rock': ['rocks'], 'rocks': ['rocks'], 'pebble': ['rocks'], 'boulder': ['rocks'],
  'bird': ['bird'], 'birdie': ['bird'],
  'tree': ['tree'], 'forest': ['forest'], 'flower': ['flower', 'blossom'], 'blossom': ['blossom', 'flower'],
  'sea': ['ocean'], 'ocean': ['ocean'], 'lake': ['lake'], 'river': ['river'],
  'waterfall': ['waterfall'], 'beach': ['beach'], 'sand': ['sand'], 'sky': ['sky'],
  'cloud': ['cloudy'], 'sunset': ['sunset_sunrise'], 'sunrise': ['sunset_sunrise'],
  'mountain': ['mountain'], 'hill': ['hill'], 'snow': ['snow'],
  // animals
  'dog': ['dog'], 'puppy': ['dog'], 'cat': ['cat'], 'kitten': ['kitten', 'cat'],
  'cow': ['cow'], 'horse': ['horse'], 'elephant': ['elephant'], 'fish': ['fish'],
  // things & places
  'car': ['car'], 'vehicle': ['vehicle'], 'bike': ['bicycle', 'motorcycle'], 'bicycle': ['bicycle'],
  'motorbike': ['motorcycle'], 'bus': ['bus'], 'train': ['train'], 'plane': ['aircraft'],
  'aeroplane': ['aircraft'], 'airplane': ['aircraft'], 'boat': ['boat'], 'ship': ['ship'],
  'phone': ['phone'], 'mobile': ['phone'], 'laptop': ['computer'], 'computer': ['computer'],
  'food': ['food'], 'cake': ['cake'], 'fruit': ['fruit'], 'building': ['building'],
  'house': ['house'], 'road': ['road'], 'wedding': ['wedding'], 'party': ['celebration'], 'celebration': ['celebration'],
  'document': ['document'], 'receipt': ['receipt'], 'screenshot': ['screenshot'],
};

String _singular(String w) {
  if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  if (w.length > 4 && (w.endsWith('sses') || w.endsWith('ches') || w.endsWith('shes') || w.endsWith('xes'))) {
    return w.substring(0, w.length - 2);
  }
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
  return w;
}

/// The words of a typed query that should name something in the picture.
List<String> objectQueryWords(Iterable<String> typed) => [
      for (final w in typed.map((w) => w.toLowerCase()))
        if (w.length >= 2 && !_stopWords.contains(w)) w,
    ];

/// Label words a typed word can match: its alias targets, else the word itself
/// (singular and as typed), so any label the classifier knows can be searched.
Set<String> objectKeys(String typed) {
  final w = typed.toLowerCase();
  final one = _singular(w);
  final alias = _aliases[w] ?? _aliases[one];
  return {...?alias, if (alias == null) ...{w, one}};
}

/// The words a label is indexed under: "wedding_dress" → wedding_dress, wedding, dress.
List<String> labelWords(String label) {
  final parts = label.split('_');
  return {label, ...parts.where((p) => p.length >= 2)}.toList();
}

/// "wedding_dress" → "wedding dress".
String labelName(String label) => label.replaceAll('_', ' ');

/// Every label word the alias table points to – checked against the classifier's list in tests.
Iterable<String> get aliasTargets => _aliases.values.expand((v) => v);
