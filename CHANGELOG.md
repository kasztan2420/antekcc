# Zmiany

## 2.0.0

Wydanie publiczne: porządki, poprawki błędów, konfiguracja z menu zamiast z kodu.
Moduły **Tracker** i **Karty Bot** bez zmian.

### Bezpieczeństwo
- Usunięty z kodu wpisany na sztywno webhook Discorda i klucz Gemini API. Oba ustawia się teraz w menu
  i trzymane są tylko w plikach konfiguracyjnych użytkownika.
- Webhook jest sprawdzany ścisłym wzorcem (`https://discord.com/api/webhooks/<id>/<token>`) przed wklejeniem
  go do linii poleceń `curl` / PowerShell — bez możliwości wstrzyknięcia poleceń.
- Usunięte domyślne nazwy gangu autora (`CWL`, pełna nazwa) — każdy ustawia swój gang.

### Poprawki błędów
- Pola tekstowe w menu psuły polskie litery `ć ę ń ó` (zamieniały je na `?`): konwersja UTF-8 → CP1250
  przetwarzała już przekonwertowane bajty drugi raz.
- Wyłączenie Górnik Bota albo Walizek nie przetrwało restartu gry (stan modułu nie był wczytywany z pliku).
- SAMPGPT przy robieniu screena (F8) przełączał Górnik Bota, który ma ten sam klawisz.
- SAMPGPT: duży napis z odpowiedzią przy wyłączonym panelu nigdy się nie pokazywał.
- SAMPGPT: zwykłe pytanie `/ai` ze słowem pasującym do początku czyjegoś nicka zamieniało się w szukanie
  gracza; początek nicka liczy się teraz tylko w pytaniu o lokalizację („gdzie jest…”).
- SAMPGPT: przy wyłączonym module `/ai` dalej było przechwytywane i kolejkowane.
- Walizki: blipy na radarze migały — co 4 s wszystkie były usuwane i tworzone od nowa.
- Gang: po ustawieniu gangu nie dało się go już zmienić z menu.

### Menu
- **Ustawienia**: wszystkie moduły z przełącznikiem i stanem na żywo, reset pozycji HUD-ów, stan zależności
  (SF.lua, SAMP-API, mimgui, samp.events) z treścią błędu w podpowiedzi.
- **Gang → Strefy**: nazwa gangu, webhook (pole maskowane), licznik wysłanych alertów, przycisk *Wyślij test*.
- **SAMPGPT**: klucz API zawsze do zmiany (pole maskowane, zapis po Enter), status klucza i `curl.exe`,
  klawisze F10/F11/F12 do zmiany lub wyłączenia, tryb OX, statystyki quizów, przycisk *Status*.
- **Bilard**: narzędzia diagnostyczne (*Stół*, *Bile*, *Tor*) dostępne z menu przy włączonej diagnostyce,
  wynik *Zmierz bilę* widoczny w menu.
- Przy pierwszym starcie jedna podpowiedź na czacie, co trzeba ustawić.
- Strefy Bot ostrzega, gdy nie ustawiono nazwy gangu.

### Wydajność
- Odczyt puli pickupów (Statuetki, Walizki): jeden `pcall` na przebieg zamiast 4096 domknięć na sekundę.
- SAMPGPT czyta plik z kluczem API najwyżej co 2 s zamiast co klatkę menu.

### Kod
- SAMPGPT korzysta z rdzenia zamiast własnych kopii: pliki, ładowanie SF.lua, FFI, procesy `curl`,
  nadzorowane wątki (`A.worker`), nazwy klawiszy.
- Usunięty martwy kod (m.in. nieużywane funkcje diagnostyczne, `oreTextInfo` w Górniku, zduplikowany
  handler `onScriptTerminate`), wspólne `A.toInt32`, `ui.textField`, `ui.right`, `ui.keyButton(..., clearable)`.
- Jedna stała wersji dla `script_version` i menu.
- `.luacheckrc` (0 ostrzeżeń) i testy `tests/run.lua` uruchamiane bez gry.
