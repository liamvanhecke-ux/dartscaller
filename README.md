# DartsCaller — X01 met AI-camera en Engelse caller

iOS 17+ · Swift/SwiftUI · SwiftData · AVFoundation · Vision · Core Image

## Structuur

| Map | Inhoud |
|---|---|
| `Core/` | Platformonafhankelijke logica (getest): bordgeometrie + homografie, X01-engine, checkouts, beeldanalyse, `ThrowTracker`, zoomberekening |
| `Vision/` | Camera (60 fps, zoom, lock), Core Image-rendering, YOLO-detector (Core ML), de AI-pipeline (bord zoeken, persoonsdetectie, pijlpunt → segment) |
| `Audio/` | `CallerAudioManager` (per pijl, beurttotaal, "You require X" bij ≤ 150) |
| `App/` | App-entry, SwiftData `Player`, `CameraSystem` (setup-flow), `GameSession` (koppelt alles) |
| `Views/` | Alle schermen |
| `Models/` | `DartsYOLO.mlpackage`: het Core ML-model voor iOS |
| `Training/` | Startmodel (`dartsense.pt`) + scripts om verder te trainen en te exporteren |
| `Tests/` | 39 XCTests (engine, regels, correcties, checkout, geometrie, detectie-toestandsmachine) |

## Installatie in Xcode (± 5 minuten)

1. **File › New › Project › iOS App.**
   - Product Name: **`DartsCaller`** (de tests importeren deze modulenaam).
   - Interface: SwiftUI. Storage: None. Vink "Include Tests" aan.
2. **Verwijder** de gegenereerde `ContentView.swift` en `DartsCallerApp.swift`.
3. **Sleep** de mappen `App`, `Core`, `Vision`, `Audio` en `Views` in het project.
   - Kies "Copy items if needed" en target *DartsCaller*.
4. **Vervang** in de testtarget de gegenereerde testfile door `Tests/DartsCallerTests.swift`.
5. **Build Settings** (target DartsCaller, zoek op de naam):

   | Setting | Waarde |
   |---|---|
   | iOS Deployment Target | 17.0 of hoger |
   | Swift Language Version | Swift 5 |
   | Default Actor Isolation *(Xcode 26)* | **nonisolated** |
   | Strict Concurrency Checking | Minimal |

   ⚠️ Default Actor Isolation moet echt op *nonisolated* staan. De camera-pipeline draait bewust op een achtergrond-queue.
6. **Info** (target › Info): voeg *Privacy – Camera Usage Description* toe, bv. "DartsCaller gebruikt de camera om je pijlen automatisch te scoren."
7. **General › Deployment Info**: alleen *Portrait* aanvinken. De kalibratie hoort bij de beeldoriëntatie.
8. Draai op een **echte iPhone/iPad**. De simulator heeft geen camera; zet daar "AI-camera" uit.
9. `⌘U` draait de tests.

## Zo werkt de camera-pipeline

1. **Bord zoeken.** De rood/groene ringen worden herkend, het bord moet 3× op dezelfde plek staan, en dan volgt **auto-zoom** tot het hele bord het beeld vult. Daarna worden focus, belichting en witbalans vergrendeld.
2. **Kalibratie.** De 4 punten staan al op een gok. Controleer ze met de loep; de gele lijnen tonen live hoe de app het bord ziet. Er wordt een homografie berekend van beeld naar mm (polaire coördinaten).
3. **Leeg bord (baseline).** Het leeg bord wordt vastgelegd zodra het beeld stil is en niemand in beeld staat.
4. **Tijdens het spel** (60 fps):
   - Beweging wordt gezien (pixeltelling op een klein beeld), gevolgd door **motion settlement** (8 stille frames).
   - Daarna volgt een **verschilanalyse** op 800 px.
   - De blob van de pijl gaat door PCA; de **punt** is het uiteinde aan de kant van de camera.
   - Via de homografie wordt dat een segment (S/D/T/25/Bull/Mis).
   - Elke 0,5 s is er ook een extra controle, voor pijlen die supersnel landen.
5. **Speler bij het bord.**
   - Vision-persoonsdetectie (10×/s) ziet iemand bij het bord, of het beeld toont dat pijlen weggehaald worden.
   - Zijn er minder dan 3 pijlen gezien, dan worden de ontbrekende **MIS** en is de beurt dicht.
   - Is het bord leeg en de speler weg, dan is automatisch de volgende speler aan de beurt.

## AI-model (YOLO) — meegeleverd

`Models/DartsYOLO.mlpackage` (5,9 MB) is een YOLOv8n-model dat pijlpunten en 6 kalibratiepunten vindt. Invoer is 800×800, NMS is ingebouwd, en het draait op de Neural Engine.

**Toevoegen in Xcode:**

1. Sleep `Models/DartsYOLO.mlpackage` in het project (target DartsCaller aanvinken). Xcode compileert het zelf.
2. Klik erop in Xcode › tab **Preview** › sleep een foto van je bord erin. Je ziet dan meteen of het model werkt.
3. In de app toont Instellingen "AI-model (YOLO): Geladen ✓".

**Werking in de app (hybride):**

| Stap | Techniek | Zonder model |
|---|---|---|
| Wanneer landt er een pijl, en welke is nieuw? | Frame-difference | idem |
| Waar zit de punt exact? | YOLO | PCA-heuristiek |
| Kalibratie | YOLO vindt tot 6 punten (min. 4, kleinste kwadraten) | kleurdetectie + slepen |
| Beeld → mm → segment | Homografie + poolcoördinaten | idem |

**Hoe goed is het?** Getest op 10 voorbeeldfoto's via de Swift-code van de app: 21/23 pijlen juist. De twee fouten waren een pijl naast het bord (daar neemt de frame-difference over) en een pijl op de draad. Die foto's zaten waarschijnlijk in de trainingsset, dus op jouw bord zal het lager liggen.

**Licentie (belangrijk):** het model komt van [Dart Sense](https://github.com/bnww/dart-sense) (Ben Willshaw) onder **CC BY-NC 4.0**. Gebruik voor jezelf of je studie mag, met naamsvermelding (staat in Instellingen › Over). **Commercieel gebruik mag niet**, dus ook geen betaalde app of app met advertenties. Wil je dat, train dan een eigen model (zie hieronder).

**Zelf (verder) trainen** (map `Training/`):

1. Maak foto's van **je eigen bord** en label ze. Gebruik de klassen uit `darts.yaml` en vakjes van 0,025.
2. `pip install ultralytics` en dan `python train.py`. Dit traint verder vanaf `dartsense.pt`; gebruik een GPU of Google Colab.
3. `python train.py --export runs/detect/train/weights/best.pt` (op Mac, Linux of Colab).
4. Hernoem het resultaat naar `DartsYOLO.mlpackage` en vervang het in Xcode.

## Zelflerend tijdens het spelen

| Lus | Wat er gebeurt | Effect |
|---|---|---|
| **Direct** (op de iPhone) | Elke correctie leert waar de camera systematisch naast zit, per zone van het bord. Worpen die je niet corrigeert bevestigen de huidige bijsturing. | Meteen: de volgende pijl in die zone wordt bijgestuurd (max. 10 mm) |
| **Model hertrainen** | Elke gedetecteerde pijl wordt een trainingsfoto. Gecorrigeerde worpen krijgen het juiste vak als label, gewone worpen hun gemeten positie. | Na een trainingsrun, dus merkbaar beter op jóuw bord |

Een model hertrainen gaat zo:

1. Instellingen › Zelflerend › **Dataset exporteren** › AirDrop de zip naar je Mac, of upload hem naar Colab.
2. `python train.py --data DartsCaller-dataset/data.yaml --epochs 30`. Dit traint verder vanaf `dartsense.pt`.
3. `python train.py --export runs/detect/train/weights/best.pt`
4. Zet het `.mlpackage` op je iPhone (AirDrop of Bestanden) en kies Instellingen › **Hertraind model importeren**. De app compileert het zelf; Xcode is niet nodig.

**Beperkingen, eerlijk:**
- Echt trainen van het YOLO-netwerk op de iPhone zelf kan niet: Core ML ondersteunt on-device updates alleen voor eenvoudige lagen. Daarom deze twee lussen.
- Een correctie zegt in welk vak de pijl zat, niet op de millimeter waar. Die labels zijn benaderd (dichtste punt in het juiste vak).
- Een correctie naar "Mis" en een ongedaan gemaakte pijl worden niet gebruikt, omdat onzeker is wat er echt in het bord zat.
- Verplaats je de camera, wis dan de geleerde correcties (de trainingsfoto's mag je houden).

## Correcties (altijd mogelijk)

- **Pijlvak aantikken:** een pijl wijzigen (T20 → S20) of een gemiste pijl toevoegen.
- **↶:** de laatste pijl ongedaan maken, ook na het einde van de beurt of de winnende pijl.
- **Menu › Beurten & correcties:** elke oude beurt aanpassen; alle standen worden herberekend.
- **Mis / Beurt bevestigen / Volgende speler:** handmatig verder als de camera iets mist.

## Tips voor de beste herkenning

- Zet een stevig statief **schuin** (30–45°) onder of naast het bord, op ± 1 m. De app waarschuwt als de camera te recht staat.
- Zorg voor gelijkmatig licht (een ringlamp is ideaal). Harde schaduwen en flikkerend licht geven valse detecties.
- Download een Engelse **Premium-stem**: Instellingen › Toegankelijkheid › Gesproken materiaal › Stemmen.

## Eerlijke beperkingen

- **Eén camera haalt nooit 100%.** Commerciële systemen (Autodarts, Scolia) gebruiken 3 camera's. Een pijl die een andere pijl afdekt, of één op een draad, kan verkeerd gelezen worden. De correctieknoppen zijn daarom altijd één tik weg.
- Het model is getraind op andere borden, andere belichting en andere camerahoeken. Een paar honderd eigen gelabelde foto's (verder trainen) maken het merkbaar beter voor jouw opstelling.
- De Core ML-conversie is op Linux gemaakt; het model draaien kon hier niet (dat kan alleen op Apple-hardware). Controleer het dus eerst in de Preview-tab van Xcode.
- De Core-logica is getest (39 tests) en `GameSession` is met een volledige wedstrijdsimulatie gecontroleerd. De camera- en UI-code kon ik niet op een iPhone draaien: test de detectie dus eerst rustig en stel eventueel de drempels in `ThrowTracker.Config` en `ImageAnalysis.ChangeParameters` bij.
