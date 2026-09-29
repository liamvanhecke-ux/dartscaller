# DartsCaller Sandbox

Testbank om worp-detectie af te stellen met opnames van **jouw** bord, en om er trainingsdata van te maken.

## Installeren (Windows, PowerShell)
```powershell
cd "$env:USERPROFILE\Documents\DartsCaller\Sandbox"
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python tests\test_sandbox.py        # moet 8/8 geven
```

## Werkwijze
| Stap | Commando |
|---|---|
| 1. Film met je iPhone op statief (1080p, 30/60 fps) een paar beurten + iemand die pijlen ophaalt | – |
| 2. Video naar de pc (bv. `opnames\sessie1.mov`) | – |
| 3. Detectie draaien (eerste keer: 4 punten aanklikken) | `python run.py --source opnames\sessie1.mov --session sessions\s1` |
| 3b. Met YOLO | `… --model ..\Training\dartsense.pt` |
| 4. Worp per worp beoordelen | `python review.py sessions\s1` |
| 5. Nauwkeurigheid + drempeladvies | `python review.py sessions\s1 --stats` |
| 6. Dataset maken | `python review.py sessions\s1 --export dataset` |
| 7. Model verder trainen | `python ..\Training\train.py --data dataset\data.yaml --epochs 30` |

Drempels aanpassen: maak `mijn_config.json`, bv. `{"min_elongation": 3.0, "cooldown_s": 0.8}`, en draai met `--config mijn_config.json`.

## Mappen
```
sessions/s1/throws/0001_throw/  before.jpg after.jpg diff.png meta.json
sessions/s1/throws/0002_ghost/  …   (afgekeurd, met reden)
dataset/confirmed/  misclassifications/  false_positives/  missed/   (+ data.yaml, YOLO-formaat)
```
