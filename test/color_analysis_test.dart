// Regressie-harness voor de kleuranalyse (BananaDetector.analyzeImageColor).
//
// Er bestond nog geen dataset/testfoto's in dit project om tegen te toetsen.
// In plaats van echte camerafoto's te vereisen, bouwen deze tests synthetische
// afbeeldingen op met bekende HSV-kleuren (via het `image`-package), zodat elke
// aanpassing aan de kleuranalyse (achtergrond-filter, hue-venster, mediaan,
// kalibratie) meteen tegen deterministische, reproduceerbare gevallen getoetst
// kan worden. Dit vervangt geen test met echte bananen in verschillend licht,
// maar voorkomt wél dat evidente regressies ongemerkt blijven.
//
// ML Kit (object detection / image labeling) wordt hier bewust NIET
// aangeroepen — dat vereist een echt platform en werkt niet in `flutter test`.
// De box wordt daarom handmatig meegegeven, precies zoals `analyzePhotoColor`
// zou doen na een succesvolle (of terugval-)detectie.

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:green_banana/banana_detector.dart';

/// HSV (h in graden 0-360, s/v in 0.0-1.0) -> RGB (0-255), voor het opbouwen
/// van testafbeeldingen met een precies bekende hue/saturatie/helderheid.
List<int> _hsvToRgb(double h, double s, double v) {
  final c = v * s;
  final hh = (h / 60.0) % 6;
  final x = c * (1 - (hh % 2 - 1).abs());
  final m = v - c;

  double r1, g1, b1;
  if (hh < 1) {
    r1 = c; g1 = x; b1 = 0;
  } else if (hh < 2) {
    r1 = x; g1 = c; b1 = 0;
  } else if (hh < 3) {
    r1 = 0; g1 = c; b1 = x;
  } else if (hh < 4) {
    r1 = 0; g1 = x; b1 = c;
  } else if (hh < 5) {
    r1 = x; g1 = 0; b1 = c;
  } else {
    r1 = c; g1 = 0; b1 = x;
  }

  return [
    (((r1 + m) * 255).round()).clamp(0, 255),
    (((g1 + m) * 255).round()).clamp(0, 255),
    (((b1 + m) * 255).round()).clamp(0, 255),
  ];
}

/// Bouwt een [size]x[size] testfoto: een crème/witte achtergrond (bewust in
/// het "achtergrond"-filterbereik van analyzeImageColor: helder + laag
/// verzadigd) met een banaankleurig blok in het midden (innerFrac van de
/// afbeelding). De geretourneerde box bevat expres een dunne rand
/// achtergrond rondom het kleurblok, zodat elke test meteen ook toetst dat
/// achtergrond-contaminatie binnen de box correct wordt weggefilterd.
({img.Image image, PixelBox box}) _buildTestImage({
  required double hue,
  required double sat,
  required double val,
  int size = 200,
  double innerFrac = 0.30,
  double outerFrac = 0.15,
}) {
  final image = img.Image(width: size, height: size);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgb(x, y, 245, 240, 225); // crème achtergrond
    }
  }

  final rgb = _hsvToRgb(hue, sat, val);
  final innerLeft = (size * innerFrac).toInt();
  final innerRight = (size * (1 - innerFrac)).toInt();
  final innerTop = (size * innerFrac).toInt();
  final innerBottom = (size * (1 - innerFrac)).toInt();
  for (int y = innerTop; y < innerBottom; y++) {
    for (int x = innerLeft; x < innerRight; x++) {
      image.setPixelRgb(x, y, rgb[0], rgb[1], rgb[2]);
    }
  }

  final box = PixelBox(
    left: (size * outerFrac).toInt(),
    top: (size * outerFrac).toInt(),
    right: (size * (1 - outerFrac)).toInt(),
    bottom: (size * (1 - outerFrac)).toInt(),
  );

  return (image: image, box: box);
}

void main() {
  final detector = BananaDetector();

  test('volledig groene banaan (hue ~95°) wordt als groen herkend', () {
    final t = _buildTestImage(hue: 95, sat: 0.55, val: 0.55);
    final result = detector.analyzeImageColor(t.image, box: t.box, boxSource: 'test');

    expect(result.primary, BananaColor.green);
    expect(result.ripenessStage, lessThanOrEqualTo(2.5));
    expect(result.medianHueRaw, closeTo(95, 10));
    expect(result.validPixelCount, greaterThan(0));
  });

  test('volledig gele banaan (hue ~50°) wordt als geel herkend', () {
    final t = _buildTestImage(hue: 50, sat: 0.85, val: 0.90);
    final result = detector.analyzeImageColor(t.image, box: t.box, boxSource: 'test');

    expect(result.primary, BananaColor.yellow);
    expect(result.ripenessStage, greaterThan(2.5));
    expect(result.ripenessStage, lessThanOrEqualTo(7.0));
  });

  test('donkere/overrijpe banaan wordt als zwart herkend', () {
    final t = _buildTestImage(hue: 30, sat: 0.5, val: 0.18);
    final result = detector.analyzeImageColor(t.image, box: t.box, boxSource: 'test');

    expect(result.primary, BananaColor.black);
    expect(result.darkSpotFraction, greaterThan(0.4));
  });

  test('groen-geel grensgeval (hue ~72°) valt nog in de groene bucket', () {
    final t = _buildTestImage(hue: 72, sat: 0.6, val: 0.55);
    final result = detector.analyzeImageColor(t.image, box: t.box, boxSource: 'test');

    expect(result.primary, BananaColor.green);
  });

  test('een box die alleen achtergrond bevat geeft "onbekend" i.p.v. een gok', () {
    final t = _buildTestImage(hue: 95, sat: 0.55, val: 0.55);
    // Box in de hoek, ver van het kleurblok in het midden.
    const backgroundOnlyBox = PixelBox(left: 2, top: 2, right: 20, bottom: 20);
    final result = detector.analyzeImageColor(t.image, box: backgroundOnlyBox, boxSource: 'test');

    expect(result.primary, BananaColor.unknown);
  });

  test(
    'grove ML Kit-achtige box (met wat contaminatie rondom) geeft nog steeds de juiste kleur',
    () {
      final t = _buildTestImage(hue: 95, sat: 0.55, val: 0.55, innerFrac: 0.30, outerFrac: 0.05);
      final result = detector.analyzeImageColor(t.image, box: t.box, boxSource: 'mlkit_object_detector');

      expect(result.primary, BananaColor.green);
      expect(result.boxSource, 'mlkit_object_detector');
    },
  );

  test('_hueToRipeness interpoleert monotoon dalend tussen de ankerpunten', () {
    // Geen directe API voor _hueToRipeness (privé) — toetsen we indirect via
    // een reeks synthetische foto's over het hele hue-bereik.
    final hues = [90.0, 80.0, 70.0, 60.0, 54.0, 49.0, 44.0, 40.0];
    double? previousStage;
    for (final hue in hues) {
      final t = _buildTestImage(hue: hue, sat: 0.6, val: 0.6);
      final result = detector.analyzeImageColor(t.image, box: t.box, boxSource: 'test');
      if (previousStage != null) {
        expect(
          result.ripenessStage,
          greaterThanOrEqualTo(previousStage - 0.15),
          reason: 'stadium mag niet dalen naarmate hue afneemt (hue=$hue)',
        );
      }
      previousStage = result.ripenessStage;
    }
  });
}
