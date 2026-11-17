/// Maps the 1,000 ImageNet classes of the MobileNetV2 model (used on Windows, where there
/// is no built-in image classifier) onto the label words the macOS classifier uses, so
/// "bird", "rocks", "dress" or "car" search the same way on both systems.
library;

import 'indexed_file.dart';

/// Model outputs this sure (summed over a category's classes) become labels.
const double kImagenetFloor = 0.25;

/// Raw class names in model output order (index = class id).
const imagenetNames = <String>[
  'tench', 'goldfish', 'great_white_shark', 'tiger_shark', 'hammerhead', 'electric_ray',
  'stingray', 'cock', 'hen', 'ostrich', 'brambling', 'goldfinch', 'house_finch', 'junco',
  'indigo_bunting', 'robin', 'bulbul', 'jay', 'magpie', 'chickadee', 'water_ouzel', 'kite',
  'bald_eagle', 'vulture', 'great_grey_owl', 'european_fire_salamander', 'common_newt', 'eft',
  'spotted_salamander', 'axolotl', 'bullfrog', 'tree_frog', 'tailed_frog', 'loggerhead',
  'leatherback_turtle', 'mud_turtle', 'terrapin', 'box_turtle', 'banded_gecko', 'common_iguana',
  'american_chameleon', 'whiptail', 'agama', 'frilled_lizard', 'alligator_lizard', 'gila_monster',
  'green_lizard', 'african_chameleon', 'komodo_dragon', 'african_crocodile', 'american_alligator',
  'triceratops', 'thunder_snake', 'ringneck_snake', 'hognose_snake', 'green_snake', 'king_snake',
  'garter_snake', 'water_snake', 'vine_snake', 'night_snake', 'boa_constrictor', 'rock_python',
  'indian_cobra', 'green_mamba', 'sea_snake', 'horned_viper', 'diamondback', 'sidewinder',
  'trilobite', 'harvestman', 'scorpion', 'black_and_gold_garden_spider', 'barn_spider',
  'garden_spider', 'black_widow', 'tarantula', 'wolf_spider', 'tick', 'centipede', 'black_grouse',
  'ptarmigan', 'ruffed_grouse', 'prairie_chicken', 'peacock', 'quail', 'partridge', 'african_grey',
  'macaw', 'sulphur_crested_cockatoo', 'lorikeet', 'coucal', 'bee_eater', 'hornbill',
  'hummingbird', 'jacamar', 'toucan', 'drake', 'red_breasted_merganser', 'goose', 'black_swan',
  'tusker', 'echidna', 'platypus', 'wallaby', 'koala', 'wombat', 'jellyfish', 'sea_anemone',
  'brain_coral', 'flatworm', 'nematode', 'conch', 'snail', 'slug', 'sea_slug', 'chiton',
  'chambered_nautilus', 'dungeness_crab', 'rock_crab', 'fiddler_crab', 'king_crab',
  'american_lobster', 'spiny_lobster', 'crayfish', 'hermit_crab', 'isopod', 'white_stork',
  'black_stork', 'spoonbill', 'flamingo', 'little_blue_heron', 'american_egret', 'bittern',
  'crane', 'limpkin', 'european_gallinule', 'american_coot', 'bustard', 'ruddy_turnstone',
  'red_backed_sandpiper', 'redshank', 'dowitcher', 'oystercatcher', 'pelican', 'king_penguin',
  'albatross', 'grey_whale', 'killer_whale', 'dugong', 'sea_lion', 'chihuahua', 'japanese_spaniel',
  'maltese_dog', 'pekinese', 'shih_tzu', 'blenheim_spaniel', 'papillon', 'toy_terrier',
  'rhodesian_ridgeback', 'afghan_hound', 'basset', 'beagle', 'bloodhound', 'bluetick',
  'black_and_tan_coonhound', 'walker_hound', 'english_foxhound', 'redbone', 'borzoi',
  'irish_wolfhound', 'italian_greyhound', 'whippet', 'ibizan_hound', 'norwegian_elkhound',
  'otterhound', 'saluki', 'scottish_deerhound', 'weimaraner', 'staffordshire_bullterrier',
  'american_staffordshire_terrier', 'bedlington_terrier', 'border_terrier', 'kerry_blue_terrier',
  'irish_terrier', 'norfolk_terrier', 'norwich_terrier', 'yorkshire_terrier',
  'wire_haired_fox_terrier', 'lakeland_terrier', 'sealyham_terrier', 'airedale', 'cairn',
  'australian_terrier', 'dandie_dinmont', 'boston_bull', 'miniature_schnauzer', 'giant_schnauzer',
  'standard_schnauzer', 'scotch_terrier', 'tibetan_terrier', 'silky_terrier',
  'soft_coated_wheaten_terrier', 'west_highland_white_terrier', 'lhasa', 'flat_coated_retriever',
  'curly_coated_retriever', 'golden_retriever', 'labrador_retriever', 'chesapeake_bay_retriever',
  'german_short_haired_pointer', 'vizsla', 'english_setter', 'irish_setter', 'gordon_setter',
  'brittany_spaniel', 'clumber', 'english_springer', 'welsh_springer_spaniel', 'cocker_spaniel',
  'sussex_spaniel', 'irish_water_spaniel', 'kuvasz', 'schipperke', 'groenendael', 'malinois',
  'briard', 'kelpie', 'komondor', 'old_english_sheepdog', 'shetland_sheepdog', 'collie',
  'border_collie', 'bouvier_des_flandres', 'rottweiler', 'german_shepherd', 'doberman',
  'miniature_pinscher', 'greater_swiss_mountain_dog', 'bernese_mountain_dog', 'appenzeller',
  'entlebucher', 'boxer', 'bull_mastiff', 'tibetan_mastiff', 'french_bulldog', 'great_dane',
  'saint_bernard', 'eskimo_dog', 'malamute', 'siberian_husky', 'dalmatian', 'affenpinscher',
  'basenji', 'pug', 'leonberg', 'newfoundland', 'great_pyrenees', 'samoyed', 'pomeranian', 'chow',
  'keeshond', 'brabancon_griffon', 'pembroke', 'cardigan', 'toy_poodle', 'miniature_poodle',
  'standard_poodle', 'mexican_hairless', 'timber_wolf', 'white_wolf', 'red_wolf', 'coyote',
  'dingo', 'dhole', 'african_hunting_dog', 'hyena', 'red_fox', 'kit_fox', 'arctic_fox', 'grey_fox',
  'tabby', 'tiger_cat', 'persian_cat', 'siamese_cat', 'egyptian_cat', 'cougar', 'lynx', 'leopard',
  'snow_leopard', 'jaguar', 'lion', 'tiger', 'cheetah', 'brown_bear', 'american_black_bear',
  'ice_bear', 'sloth_bear', 'mongoose', 'meerkat', 'tiger_beetle', 'ladybug', 'ground_beetle',
  'long_horned_beetle', 'leaf_beetle', 'dung_beetle', 'rhinoceros_beetle', 'weevil', 'fly', 'bee',
  'ant', 'grasshopper', 'cricket', 'walking_stick', 'cockroach', 'mantis', 'cicada', 'leafhopper',
  'lacewing', 'dragonfly', 'damselfly', 'admiral', 'ringlet', 'monarch', 'cabbage_butterfly',
  'sulphur_butterfly', 'lycaenid', 'starfish', 'sea_urchin', 'sea_cucumber', 'wood_rabbit', 'hare',
  'angora', 'hamster', 'porcupine', 'fox_squirrel', 'marmot', 'beaver', 'guinea_pig', 'sorrel',
  'zebra', 'hog', 'wild_boar', 'warthog', 'hippopotamus', 'ox', 'water_buffalo', 'bison', 'ram',
  'bighorn', 'ibex', 'hartebeest', 'impala', 'gazelle', 'arabian_camel', 'llama', 'weasel', 'mink',
  'polecat', 'black_footed_ferret', 'otter', 'skunk', 'badger', 'armadillo', 'three_toed_sloth',
  'orangutan', 'gorilla', 'chimpanzee', 'gibbon', 'siamang', 'guenon', 'patas', 'baboon',
  'macaque', 'langur', 'colobus', 'proboscis_monkey', 'marmoset', 'capuchin', 'howler_monkey',
  'titi', 'spider_monkey', 'squirrel_monkey', 'madagascar_cat', 'indri', 'indian_elephant',
  'african_elephant', 'lesser_panda', 'giant_panda', 'barracouta', 'eel', 'coho', 'rock_beauty',
  'anemone_fish', 'sturgeon', 'gar', 'lionfish', 'puffer', 'abacus', 'abaya', 'academic_gown',
  'accordion', 'acoustic_guitar', 'aircraft_carrier', 'airliner', 'airship', 'altar', 'ambulance',
  'amphibian', 'analog_clock', 'apiary', 'apron', 'ashcan', 'assault_rifle', 'backpack', 'bakery',
  'balance_beam', 'balloon', 'ballpoint', 'band_aid', 'banjo', 'bannister', 'barbell',
  'barber_chair', 'barbershop', 'barn', 'barometer', 'barrel', 'barrow', 'baseball', 'basketball',
  'bassinet', 'bassoon', 'bathing_cap', 'bath_towel', 'bathtub', 'beach_wagon', 'beacon', 'beaker',
  'bearskin', 'beer_bottle', 'beer_glass', 'bell_cote', 'bib', 'bicycle_built_for_two', 'bikini',
  'binder', 'binoculars', 'birdhouse', 'boathouse', 'bobsled', 'bolo_tie', 'bonnet', 'bookcase',
  'bookshop', 'bottlecap', 'bow', 'bow_tie', 'brass', 'brassiere', 'breakwater', 'breastplate',
  'broom', 'bucket', 'buckle', 'bulletproof_vest', 'bullet_train', 'butcher_shop', 'cab',
  'caldron', 'candle', 'cannon', 'canoe', 'can_opener', 'cardigan', 'car_mirror', 'carousel',
  'carpenter_s_kit', 'carton', 'car_wheel', 'cash_machine', 'cassette', 'cassette_player',
  'castle', 'catamaran', 'cd_player', 'cello', 'cellular_telephone', 'chain', 'chainlink_fence',
  'chain_mail', 'chain_saw', 'chest', 'chiffonier', 'chime', 'china_cabinet', 'christmas_stocking',
  'church', 'cinema', 'cleaver', 'cliff_dwelling', 'cloak', 'clog', 'cocktail_shaker',
  'coffee_mug', 'coffeepot', 'coil', 'combination_lock', 'computer_keyboard', 'confectionery',
  'container_ship', 'convertible', 'corkscrew', 'cornet', 'cowboy_boot', 'cowboy_hat', 'cradle',
  'crane', 'crash_helmet', 'crate', 'crib', 'crock_pot', 'croquet_ball', 'crutch', 'cuirass',
  'dam', 'desk', 'desktop_computer', 'dial_telephone', 'diaper', 'digital_clock', 'digital_watch',
  'dining_table', 'dishrag', 'dishwasher', 'disk_brake', 'dock', 'dogsled', 'dome', 'doormat',
  'drilling_platform', 'drum', 'drumstick', 'dumbbell', 'dutch_oven', 'electric_fan',
  'electric_guitar', 'electric_locomotive', 'entertainment_center', 'envelope', 'espresso_maker',
  'face_powder', 'feather_boa', 'file', 'fireboat', 'fire_engine', 'fire_screen', 'flagpole',
  'flute', 'folding_chair', 'football_helmet', 'forklift', 'fountain', 'fountain_pen',
  'four_poster', 'freight_car', 'french_horn', 'frying_pan', 'fur_coat', 'garbage_truck',
  'gasmask', 'gas_pump', 'goblet', 'go_kart', 'golf_ball', 'golfcart', 'gondola', 'gong', 'gown',
  'grand_piano', 'greenhouse', 'grille', 'grocery_store', 'guillotine', 'hair_slide', 'hair_spray',
  'half_track', 'hammer', 'hamper', 'hand_blower', 'hand_held_computer', 'handkerchief',
  'hard_disc', 'harmonica', 'harp', 'harvester', 'hatchet', 'holster', 'home_theater', 'honeycomb',
  'hook', 'hoopskirt', 'horizontal_bar', 'horse_cart', 'hourglass', 'ipod', 'iron',
  'jack_o_lantern', 'jean', 'jeep', 'jersey', 'jigsaw_puzzle', 'jinrikisha', 'joystick', 'kimono',
  'knee_pad', 'knot', 'lab_coat', 'ladle', 'lampshade', 'laptop', 'lawn_mower', 'lens_cap',
  'letter_opener', 'library', 'lifeboat', 'lighter', 'limousine', 'liner', 'lipstick', 'loafer',
  'lotion', 'loudspeaker', 'loupe', 'lumbermill', 'magnetic_compass', 'mailbag', 'mailbox',
  'maillot', 'maillot', 'manhole_cover', 'maraca', 'marimba', 'mask', 'matchstick', 'maypole',
  'maze', 'measuring_cup', 'medicine_chest', 'megalith', 'microphone', 'microwave',
  'military_uniform', 'milk_can', 'minibus', 'miniskirt', 'minivan', 'missile', 'mitten',
  'mixing_bowl', 'mobile_home', 'model_t', 'modem', 'monastery', 'monitor', 'moped', 'mortar',
  'mortarboard', 'mosque', 'mosquito_net', 'motor_scooter', 'mountain_bike', 'mountain_tent',
  'mouse', 'mousetrap', 'moving_van', 'muzzle', 'nail', 'neck_brace', 'necklace', 'nipple',
  'notebook', 'obelisk', 'oboe', 'ocarina', 'odometer', 'oil_filter', 'organ', 'oscilloscope',
  'overskirt', 'oxcart', 'oxygen_mask', 'packet', 'paddle', 'paddlewheel', 'padlock', 'paintbrush',
  'pajama', 'palace', 'panpipe', 'paper_towel', 'parachute', 'parallel_bars', 'park_bench',
  'parking_meter', 'passenger_car', 'patio', 'pay_phone', 'pedestal', 'pencil_box',
  'pencil_sharpener', 'perfume', 'petri_dish', 'photocopier', 'pick', 'pickelhaube',
  'picket_fence', 'pickup', 'pier', 'piggy_bank', 'pill_bottle', 'pillow', 'ping_pong_ball',
  'pinwheel', 'pirate', 'pitcher', 'plane', 'planetarium', 'plastic_bag', 'plate_rack', 'plow',
  'plunger', 'polaroid_camera', 'pole', 'police_van', 'poncho', 'pool_table', 'pop_bottle', 'pot',
  'potter_s_wheel', 'power_drill', 'prayer_rug', 'printer', 'prison', 'projectile', 'projector',
  'puck', 'punching_bag', 'purse', 'quill', 'quilt', 'racer', 'racket', 'radiator', 'radio',
  'radio_telescope', 'rain_barrel', 'recreational_vehicle', 'reel', 'reflex_camera',
  'refrigerator', 'remote_control', 'restaurant', 'revolver', 'rifle', 'rocking_chair',
  'rotisserie', 'rubber_eraser', 'rugby_ball', 'rule', 'running_shoe', 'safe', 'safety_pin',
  'saltshaker', 'sandal', 'sarong', 'sax', 'scabbard', 'scale', 'school_bus', 'schooner',
  'scoreboard', 'screen', 'screw', 'screwdriver', 'seat_belt', 'sewing_machine', 'shield',
  'shoe_shop', 'shoji', 'shopping_basket', 'shopping_cart', 'shovel', 'shower_cap',
  'shower_curtain', 'ski', 'ski_mask', 'sleeping_bag', 'slide_rule', 'sliding_door', 'slot',
  'snorkel', 'snowmobile', 'snowplow', 'soap_dispenser', 'soccer_ball', 'sock', 'solar_dish',
  'sombrero', 'soup_bowl', 'space_bar', 'space_heater', 'space_shuttle', 'spatula', 'speedboat',
  'spider_web', 'spindle', 'sports_car', 'spotlight', 'stage', 'steam_locomotive',
  'steel_arch_bridge', 'steel_drum', 'stethoscope', 'stole', 'stone_wall', 'stopwatch', 'stove',
  'strainer', 'streetcar', 'stretcher', 'studio_couch', 'stupa', 'submarine', 'suit', 'sundial',
  'sunglass', 'sunglasses', 'sunscreen', 'suspension_bridge', 'swab', 'sweatshirt',
  'swimming_trunks', 'swing', 'switch', 'syringe', 'table_lamp', 'tank', 'tape_player', 'teapot',
  'teddy', 'television', 'tennis_ball', 'thatch', 'theater_curtain', 'thimble', 'thresher',
  'throne', 'tile_roof', 'toaster', 'tobacco_shop', 'toilet_seat', 'torch', 'totem_pole',
  'tow_truck', 'toyshop', 'tractor', 'trailer_truck', 'tray', 'trench_coat', 'tricycle',
  'trimaran', 'tripod', 'triumphal_arch', 'trolleybus', 'trombone', 'tub', 'turnstile',
  'typewriter_keyboard', 'umbrella', 'unicycle', 'upright', 'vacuum', 'vase', 'vault', 'velvet',
  'vending_machine', 'vestment', 'viaduct', 'violin', 'volleyball', 'waffle_iron', 'wall_clock',
  'wallet', 'wardrobe', 'warplane', 'washbasin', 'washer', 'water_bottle', 'water_jug',
  'water_tower', 'whiskey_jug', 'whistle', 'wig', 'window_screen', 'window_shade', 'windsor_tie',
  'wine_bottle', 'wing', 'wok', 'wooden_spoon', 'wool', 'worm_fence', 'wreck', 'yawl', 'yurt',
  'web_site', 'comic_book', 'crossword_puzzle', 'street_sign', 'traffic_light', 'book_jacket',
  'menu', 'plate', 'guacamole', 'consomme', 'hot_pot', 'trifle', 'ice_cream', 'ice_lolly',
  'french_loaf', 'bagel', 'pretzel', 'cheeseburger', 'hotdog', 'mashed_potato', 'head_cabbage',
  'broccoli', 'cauliflower', 'zucchini', 'spaghetti_squash', 'acorn_squash', 'butternut_squash',
  'cucumber', 'artichoke', 'bell_pepper', 'cardoon', 'mushroom', 'granny_smith', 'strawberry',
  'orange', 'lemon', 'fig', 'pineapple', 'banana', 'jackfruit', 'custard_apple', 'pomegranate',
  'hay', 'carbonara', 'chocolate_sauce', 'dough', 'meat_loaf', 'pizza', 'potpie', 'burrito',
  'red_wine', 'espresso', 'cup', 'eggnog', 'alp', 'bubble', 'cliff', 'coral_reef', 'geyser',
  'lakeside', 'promontory', 'sandbar', 'seashore', 'valley', 'volcano', 'ballplayer', 'groom',
  'scuba_diver', 'rapeseed', 'daisy', 'yellow_lady_s_slipper', 'corn', 'acorn', 'hip', 'buckeye',
  'coral_fungus', 'agaric', 'gyromitra', 'stinkhorn', 'earthstar', 'hen_of_the_woods', 'bolete',
  'ear', 'toilet_tissue',
];

bool _in(int i, int a, int b) => i >= a && i <= b;

/// Category labels for one ImageNet class (besides its own name).
List<String> imagenetCategories(int i) {
  if (_in(i, 0, 6) || _in(i, 389, 397)) return const ['fish', 'animal'];
  if (_in(i, 7, 24) || _in(i, 80, 100) || _in(i, 127, 146)) return const ['bird', 'animal'];
  if (_in(i, 151, 268)) return const ['dog', 'animal'];
  if (_in(i, 281, 285)) return const ['cat', 'animal'];
  if (_in(i, 321, 326)) return const ['butterfly', 'insect', 'animal'];
  if (_in(i, 300, 320)) return const ['insect', 'animal'];
  if (i == 339) return const ['horse', 'animal'];
  if (i == 345 || i == 346 || i == 347) return const ['cow', 'animal'];
  if (i == 385 || i == 386 || i == 101) return const ['elephant', 'animal'];
  // 107–111 (jellyfish, anemone, coral, flatworm, nematode) are left out: on abstract
  // backgrounds and app graphics the model "sees" them constantly.
  if (_in(i, 107, 111)) return const [];
  if (_in(i, 25, 79) || _in(i, 102, 106) || _in(i, 112, 126) || _in(i, 147, 150) || _in(i, 269, 280) ||
      _in(i, 286, 299) || _in(i, 327, 388)) {
    return const ['animal'];
  }
  return _objects[i] ?? const [];
}

/// Draped / long garments: MobileNet has no "sari" class, but saree photos come out as
/// these (tested on real photos), so they also count as a weaker "sari".
const _drapedGarments = {399, 501, 578, 601, 614, 689, 775, 824, 887};
const double _sariShare = 0.6;

/// Clothing being worn: ImageNet has no "person" class, but a photo of a gown, kimono or
/// suit nearly always shows someone wearing it – so "woman wearing saree" can match.
const _wornGarments = {
  399, 400, 457, 474, 501, 568, 578, 601, 608, 610, 614, 617, 638, 639, 652, 655, 689, 697,
  735, 775, 824, 834, 841, 842, 869, 887, 906,
};
const double _peopleShare = 0.5;

const _objects = <int, List<String>>{
  // clothing
  399: ['clothing', 'dress'], 400: ['clothing', 'gown'], 457: ['clothing', 'necktie'],
  459: ['clothing'], 474: ['clothing'], 501: ['clothing', 'dress'], 568: ['clothing'],
  578: ['clothing', 'dress', 'gown'], 601: ['clothing', 'dress'], 608: ['clothing', 'jeans'],
  610: ['clothing'], 614: ['clothing', 'dress', 'kimono'], 617: ['clothing'], 638: ['clothing'],
  639: ['clothing'], 652: ['clothing'], 655: ['clothing'], 689: ['clothing', 'dress'],
  697: ['clothing'], 735: ['clothing'], 775: ['clothing', 'dress'], 824: ['clothing'],
  834: ['clothing', 'suit'], 841: ['clothing'], 842: ['clothing'], 869: ['clothing'],
  887: ['clothing', 'dress'], 906: ['clothing', 'necktie'],
  // people (ImageNet has no "person" class – these are the people-shaped ones)
  981: ['people'], 982: ['people'], 983: ['people'],
  // vehicles
  404: ['aircraft', 'airplane', 'vehicle'], 895: ['aircraft', 'airplane', 'vehicle'],
  405: ['aircraft', 'vehicle'],
  407: ['car', 'vehicle'], 436: ['car', 'vehicle'], 468: ['car', 'vehicle'], 511: ['car', 'vehicle'],
  609: ['car', 'vehicle'], 627: ['car', 'vehicle'], 656: ['car', 'vehicle'], 661: ['car', 'vehicle'],
  717: ['car', 'vehicle'], 751: ['car', 'vehicle'], 817: ['car', 'vehicle'], 734: ['vehicle'],
  675: ['vehicle'], 757: ['vehicle'], 864: ['vehicle'], 867: ['vehicle'],
  654: ['bus', 'vehicle'], 779: ['bus', 'vehicle'], 874: ['bus', 'vehicle'],
  444: ['bicycle', 'vehicle'], 671: ['bicycle', 'vehicle'], 870: ['bicycle', 'vehicle'],
  665: ['motorcycle', 'vehicle'], 670: ['motorcycle', 'vehicle'],
  466: ['train', 'vehicle'], 547: ['train', 'vehicle'], 565: ['train', 'vehicle'],
  705: ['train', 'vehicle'], 820: ['train', 'vehicle'], 829: ['train', 'vehicle'],
  472: ['boat'], 484: ['boat'], 554: ['boat'], 576: ['boat'], 625: ['boat'], 694: ['boat'],
  780: ['boat'], 814: ['boat'], 871: ['boat'], 914: ['boat'],
  403: ['ship'], 510: ['ship'], 628: ['ship'], 724: ['ship'], 833: ['ship'],
  // devices
  487: ['phone'], 527: ['computer'], 620: ['computer'], 681: ['computer'],
  // buildings & places
  497: ['building'], 663: ['building'], 668: ['building'], 698: ['building'], 832: ['building'],
  483: ['building'], 821: ['bridge'], 839: ['bridge'], 888: ['bridge'],
  // nature
  970: ['mountain'], 979: ['mountain', 'valley'], 980: ['mountain'],
  972: ['rocks', 'cliff'], 976: ['rocks', 'cliff'], 825: ['rocks'],
  977: ['beach', 'sand'], 978: ['beach', 'ocean'], 975: ['lake'], 973: ['ocean', 'underwater'],
  985: ['flower'], 986: ['flower'],
};

/// [top] = (class id, probability) pairs from the model. Returns labels like the macOS
/// classifier's: category probabilities are summed (ten bird species at 0.08 each are
/// a confident "bird"), raw class names kept when the model is sure of them.
List<ImageLabel> labelsFromImagenet(Iterable<(int, double)> top) {
  final score = <String, double>{}; // categories: summed over their classes
  final raw = <String, double>{}; // a class's own name: its own probability
  void add(String id, double p) => score[id] = ((score[id] ?? 0) + p).clamp(0.0, 1.0);
  for (final (i, p) in top) {
    if (i < 0 || i >= imagenetNames.length) continue;
    raw[imagenetNames[i]] = p;
    for (final c in imagenetCategories(i)) {
      add(c, p);
    }
    if (_drapedGarments.contains(i)) add('sari', p * _sariShare);
    if (_wornGarments.contains(i)) add('people', p * _peopleShare);
    if (_in(i, 948, 957)) add('fruit', p);
    if (_in(i, 936, 947)) add('vegetable', p);
    if (_in(i, 923, 969)) add('food', p);
  }
  // A name can be both ("gown" class and "gown" category): keep the higher score.
  for (final e in raw.entries) {
    score[e.key] = (score[e.key] ?? 0) > e.value ? score[e.key]! : e.value;
  }
  final out = [
    for (final e in score.entries)
      if (e.value >= kImagenetFloor) ImageLabel(e.key, e.value),
  ]..sort((a, b) => b.confidence.compareTo(a.confidence));
  return out.take(16).toList();
}
