# antek.cc

Skrypt MoonLoadera dla GTA San Andreas Multiplayer: kilka narzędzi w jednym menu (mimgui).
Jeden plik, `antek.lua`, w 100% ASCII — kodowanie pliku nie ma znaczenia dla MoonLoadera.

## Moduły

| Zakładka | Moduł | Co robi |
|---|---|---|
| Tracker | Tracker | Śledzenie gracza (stream / synchronizacja / marker), dystans, kierunek, najbliższy teleport serwera |
| | Statuetki | Znalezione statuetki (pickup 1276) na radarze, zapis do `pickupy_dump.txt` |
| | Walizki | Walizki (model 19624) w zasięgu na radarze; podniesiona znika |
| Gang | Graffiti | Graffiti na radarze w kolorze gangu, HUD przejęć, auto `/graffiti` w tle |
| | Strefy | Stan stref (`/strefy` + czat), HUD ataku i HUD wroga, alerty Discord |
| | Strefy Bot | Dojazd na checkpoint strefy (NRG-500 albo pieszo), `Y`, przejęcie, następna — szczegóły niżej |
| Boty | Karty Bot | Kasyno: automatyczna gra w karty |
| | Górnik Bot | Klawisze przy wydobyciu, pełny automat (bieg do rud, sprzedaż), znaczniki rud |
| | Makro | Szybkie wciskanie klawisza (domyślnie `Y`) |
| Narzędzia | Wykrywacz TNT | HUD z odległością i kierunkiem do najbliższego TNT, napisy 3D, radar, alarm na czacie |
| | Celownik | Model i odległość obiektu na środku ekranu; ukrywanie obiektów (znikają i nie mają kolizji, tylko u Ciebie) |
| | Pojazdy RC | Wsiadanie do RC Goblin / Bandit / Baron / Raider / Tiger / Cam klawiszem F |
| Bilard | Bilard | Tor bili, odbicia, łuzy, zalecana siła, planer zagrania, kalibracja |
| SAMPGPT | SAMPGPT | Asystent AI (Gemini): `/ai`, quizy i rebusy z czatu/ekranu, OX, mapa z pamięci gry |
| Ustawienia | — | Klawisz menu, panic key |

## Wymagania

- GTA San Andreas + SA-MP 0.3.7 i MoonLoader
- `moonloader/lib`: **SF.lua**, **SAMP-API** (`sampapi`), **mimgui**
- opcjonalnie: `lib.samp.events` (Bilard: pasek siły bez odczytu textdrawów), `memory` (Bilard: obrót stołu z macierzy), `encoding` (SAMPGPT: polskie znaki w zapytaniach)
- SAMPGPT i alerty Discord: `curl.exe` (Windows 10+ ma go w `System32`; alerty mają też zapas przez PowerShell)
- Strefy w tle po alt-tabie: `BackgroundPlay.lua`

## Instalacja

1. Skopiuj `antek.lua` do folderu `moonloader`.
2. Uruchom grę, wejdź na serwer, naciśnij **Insert**.

Gang (*Imperium orczych bagniakow CWL*, tag `CWL`), webhook Discorda i klucz Gemini API są wpisane na stałe
w `antek.lua` — nic nie trzeba ustawiać.

Stare ustawienia (`TagBlips.json`, `pooltracer.lua`, `PlayerTracker_*.txt`) są importowane automatycznie przy pierwszym starcie.

## Klawisze domyślne

Wszystkie zmienisz w menu.

| Klawisz | Akcja |
|---|---|
| `Insert` | menu |
| — | panic key: natychmiast wyłącza cały skrypt (ustaw w Ustawieniach) |
| `F2` | Strefy Bot start / stop |
| `F8` | Górnik Bot start / stop (uwaga: to też klawisz screenshota SA-MP) |
| `F9` | Karty Bot start / stop |
| `←` / `→` | Makro włącz / wyłącz |
| `F10` / `F11` / `F12` | SAMPGPT: mapa / wpisz ostatnią odpowiedź / OX z ekranu |
| `Delete` | ukryj obiekt na celowniku (środek ekranu) |
| `F` | wsiądź do pojazdu RC (do 5 m) |
| `/ai <pytanie>` | SAMPGPT na czacie |

HUD-y przeciągasz myszą, gdy menu jest otwarte.

## Pliki

| Ścieżka | Zawartość |
|---|---|
| `moonloader/config/antek/antek.json` | menu, klawisze, moduły, pozycje HUD |
| `moonloader/config/antek/*.json` | ustawienia modułów (`graffiti`, `strefy`, `tracker`, `gornik`, `rudy`, `karta`, `autoy`, `statuetki`, `walizki`, `narzedzia` — modele TNT i ukryte obiekty) |
| `moonloader/config/antek/pool.lua` | kalibracja bilarda |
| `moonloader/config/antek/strefy_log.txt` | log alertów stref (rotacja przy 1 MB) |
| `moonloader/config/sampgpt_*.txt` | SAMPGPT: klucz, ustawienia, baza odpowiedzi, wiedza o serwerze, statystyki |
| `moonloader/pickupy_dump.txt`, `walizki_dump.txt` | znalezione statuetki / walizki |
| `moonloader/moonloader.log` | diagnostyka wszystkich modułów |

Webhook Discorda i klucz Gemini są wpisane w `antek.lua` — nie publikuj tego pliku (ani repo) publicznie.
Uszkodzony plik JSON jest odkładany jako `.bak`, a moduł startuje z ustawieniami domyślnymi.

## Wykrywacz TNT — pierwsze użycie

Skrypt nie zna z góry modelu TNT (serwer robi je z klocka z teksturą). Raz: podejdź do TNT, wyceluj w nie kropką
na środku ekranu i w menu **Narzędzia → Celownik** kliknij **To TNT** (albo znajdź je na liście *Obiekty w pobliżu*).
Model zapisuje się na stałe; od tej chwili każde TNT w zasięgu jest na HUD-zie, radarze i z napisem 3D.
Jeśli ten sam model serwer używa też do innych klocków, detektor pokaże i je.

## Strefy Bot — jak jeździ

- **Trasa:** daleko — po sieci dróg z pamięci gry (A* z karą za skręty, liczone w tle, sieć budowana od startu bota);
  ostatnie 70 m — A* po kolizji gry dla motoru (szerokie przejścia, krawężniki do 0,4 m), liczone,
  gdy motor jeszcze jedzie po drodze. W czasie liczenia bot jedzie dalej, nie staje.
- **Ściany i przeszkody:** wachlarz 21 promieni przed motorem (gęściej na wprost). Bot trzyma się trasy, dopóki droga
  jest wolna na odległość hamowania; inaczej wybiera najbliższy wolny kierunek i trzyma się raz wybranej strony omijania.
  Prędkość ograniczana odległością do przeszkody i ostrością skrętu.
- **Zakręty:** punkt pure pursuit skracany przed zakrętem (bez ścinania narożników budynków), płynnie wydłużany za nim.
- **Bez postojów:** w trakcie 60 s przejmowania strefy `/strefy` odświeża się w tle, a trasa do następnej strefy
  liczy się z góry — po przejęciu bot od razu rusza.

## Rozwój

```sh
luarocks install luacheck
luacheck antek.lua tests/     # konfiguracja: .luacheckrc
luajit tests/run.lua          # testy bez gry: atrapy API MoonLoadera i mimgui
luajit tests/sim_drive.lua    # Strefy Bot w symulatorze jazdy (budynki, motor, raycasty z kosztem jak w grze)
luajit tests/sim_drive.lua zaulek trace   # jeden scenariusz z przebiegiem co 0,5 s
```

`tests/run.lua` ładuje cały skrypt pod czystym LuaJIT i sprawdza m.in. JSON, kodowanie CP1250 ↔ UTF-8,
parsery stref, zapis konfiguracji, `init()` / `frame()` wszystkich modułów oraz render i kliknięcia
każdej zakładki menu. `tests/sim_drive.lua` puszcza bota w 16 scenariuszach (ściana na wprost, brama, wąska
szczelina, zaułek, auto na jezdni, las słupów, miasto z drogami i bez, 30 m/s…) i wymaga dojazdu bez ani jednej kolizji.

Nowy moduł: `A.register{ id, title, init, frame, menu, ... }` — opis kontraktu na początku `antek.lua`.
