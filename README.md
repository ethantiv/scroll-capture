# ScrollCapture

Aplikacja w pasku menu macOS, która robi przewijany zrzut ekranu okna. Naciśnij **⌃⌥⌘S**, zaznacz obszar myszą albo naciśnij Spację, żeby objąć cały przewijany obszar pod kursorem. Aplikacja sama przewija okno, skleja klatki i kopiuje obraz PNG do schowka.

## Wymagania

- macOS 27 na Macu z procesorem Apple
- Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Certyfikat do podpisywania kodu o nazwie `Local Self-Signed` w pęku kluczy logowania

Jeśli nie masz certyfikatu, utwórz go w aplikacji Dostęp do pęku kluczy: **Dostęp do pęku kluczy > Asystent certyfikatów > Utwórz certyfikat**, nazwa `Local Self-Signed`, typ certyfikatu **Podpisywanie kodu**. Dzięki stałemu certyfikatowi macOS pamięta nadane uprawnienia po każdej przebudowie.

## Budowanie i instalacja

1. Sklonuj repozytorium i przejdź do jego katalogu:

   ```bash
   git clone https://github.com/ethantiv/scroll-capture.git
   cd scroll-capture
   ```

2. Zbuduj wersję Release i zainstaluj ją w `/Applications`:

   ```bash
   scripts/install.sh
   ```

   Skrypt zastępuje poprzednią kopię `/Applications/ScrollCapture.app` i uruchamia aplikację. Ikona pojawia się w pasku menu.

3. Przy pierwszym zrzucie nadaj aplikacji uprawnienia w **Ustawieniach systemowych > Prywatność i ochrona**:
   - **Dostępność**: aplikacja przewija okno syntetycznymi zdarzeniami.
   - **Nagrywanie ekranu**: aplikacja robi zrzuty okna.

## Inne skrypty

| Skrypt | Działanie |
|---|---|
| `scripts/build.sh` | Buduje wersję Debug |
| `scripts/run.sh` | Buduje wersję Debug i uruchamia ją zamiast poprzedniej |
| `scripts/test.sh` | Uruchamia testy; z `--adhoc` nie potrzebuje certyfikatu |
