# MacLister

Menedżer plików oparty na listerach dla macOS, w duchu **Directory Opus Magellan**: dwuklik w puste miejsce
pulpitu otwiera lister dokładnie tam, gdzie kliknąłeś. Natywna aplikacja w Swift (AppKit + SwiftUI),
działa jako agent w pasku menu, bez ikony w Docku.

**Język:** [English](README.md) · Polski

## Najważniejsze cechy

- **Dwuklik na pulpicie otwiera lister** pod kursorem. Dowolna liczba listerów naraz.
- **Listery źródłowy i docelowy**: Copy (F5), Move (F6), Extract, Compare, Swap.
- **Przeciąganie i upuszczanie** między listerami oraz z/do Findera (reguły Findera: ten sam wolumin przenosi,
  ⌥ kopiuje, ⌘ przenosi).
- **Konfigurowalny pasek przycisków**, **akcje dla typów plików** (co robi dwuklik), **zakładki**, **zapisane układy**.
- Zaznaczanie wzorcem, filtr, rozmiary folderów, panel informacji, zmiana nazwy, duplikowanie, Quick Look na
  Spacji, rozpakowywanie archiwów (zip, tar.\*, 7z, rar, gz, bz2 …).
- **Prawy przycisk na belce okna** otwiera polecenia listera (duplikuj, źródło/cel, zamknij wszystkie …).

## Wymagania

macOS 13 Ventura lub nowszy. Apple Silicon albo Intel (wersja uniwersalna; część dla Intela nie była
uruchamiana na prawdziwym sprzęcie Intel).

## Instalacja

1. Pobierz `MacLister-<wersja>-macos.zip` ze strony **Releases** tego repozytorium. Opcjonalnie sprawdź sumę:
   `shasum -a 256 -c MacLister-<wersja>-macos.zip.sha256`.
2. Rozpakuj i przeciągnij **MacLister.app** do `/Applications`.
3. **Pierwsze uruchomienie.** Aplikacja jest podpisana ad-hoc i nie ma notaryzacji, więc Gatekeeper z początku ją
   blokuje:
   - kliknij aplikację z klawiszem Control → **Otwórz** → **Otwórz**, albo
   - Ustawienia systemowe → Prywatność i ochrona → **Otwórz mimo to** (macOS 15 i nowsze), albo
   - raz wykonaj `xattr -dr com.apple.quarantine /Applications/MacLister.app`.
4. **Nadaj dwa uprawnienia** w Ustawieniach systemowych → Prywatność i ochrona:
   - **Dostępność** – żeby rozpoznać, co jest pod kursorem (puste miejsce, ikona, okno, Dock).
   - **Monitorowanie wprowadzania** – macOS wymaga go dla pasywnego nasłuchu, który widzi dwuklik.

   Włącz oba dla MacLister, potem **zamknij i uruchom aplikację ponownie** (ikona w pasku menu → *Quit MacLister*).
5. Kliknij ikonę w pasku menu. Pierwsza linia powinna brzmieć **Desktop double-click: active**.
6. *Zalecane:* wyłącz systemowe odsłanianie pulpitu. Inaczej pierwszy klik dwukliku odsuwa wszystkie okna
   na bok, a nowy lister może wylądować częściowo poza ekranem.
   Ustawienia systemowe → Pulpit i Dock → **Kliknij tapetę, aby odsłonić pulpit** → *Tylko w Stage Manager*, albo:

   ```bash
   defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
   ```

7. *Opcjonalnie:* uruchamianie przy logowaniu: Ustawienia systemowe → Ogólne → Elementy logowania → **+** → MacLister.

**Odinstalowanie:** zamknij aplikację z ikony w pasku menu, usuń ją, usuń `~/Library/Application Support/MacLister`,
wykonaj `defaults delete com.example.MacLister` i usuń MacLister z dwóch list uprawnień.

## Użycie

### Otwieranie listera

- **Dwuklik w puste miejsce pulpitu.** Na ikonach, oknach, pasku menu i Docku nic się nie dzieje, a kliknięcia
  z wciśniętym ⌘/⇧/⌥/⌃ są ignorowane. Wolisz rolkę myszy? Ikona w pasku menu → **Open Lister With** pozwala
  otwierać lister **pojedynczym kliknięciem środkowego przycisku** zamiast dwukliku albo oprócz niego.
- Albo ikona w pasku menu → **New Lister**.
- Domyślnie lewy górny róg okna leży w punkcie kliknięcia; ikona w pasku menu → **Center Lister on Cursor**
  wyśrodkowuje okno. Lister otwiera się w folderze domowym (zob. *startDirectory* niżej).

### Budowa listera

- **Pasek ścieżki:** *Back*, *Parent*, menu **Go** (miejsca, woluminy, zakładki, ostatnie foldery), ścieżka jako
  klikalny **breadcrumb** (kliknij folder, żeby tam przejść; kliknij puste miejsce paska albo naciśnij **⌘L**, żeby
  wpisać ścieżkę, `~` działa) oraz znaczki **SRC** / **DST**.
- **Lista plików:** ikona, nazwa, rozmiar, data modyfikacji. Kliknięcie nagłówka sortuje; foldery zawsze są
  na początku. Dwuklik lub Return otwiera plik albo wchodzi do folderu. **Prawy przycisk na nagłówku kolumn**
  wybiera kolumny: Size, Modified, Created, Kind, Extension, Permissions, Tags, Comment.
- **Lista odświeża się sama**, gdy pliki są dodawane, usuwane lub zmieniane na dysku (FSEvents), a podtytuł okna
  pokazuje wolne miejsce na woluminie.
- **Pasek przycisków** nad paskiem ścieżki, jak w Ambiencie na MorphOS (zob. *Konfiguracja*): same ikony, nazwa
  w podpowiedzi. Ikona w pasku menu → **Button Bar** ustawia go nad ścieżką, pod ścieżką albo na dole;
  **Show Button Labels** dodaje napisy.
- Cienka **linia stanu** na dole: liczba elementów, rozmiar zaznaczenia, filtr, postęp i błędy.
- Nowe listery mają 560 × 400 i pamiętają rozmiar, który ostatnio nadałeś listerowi przeciągając krawędź.
- Podtytuł okna pokazuje liczbę elementów i rolę listera (SOURCE / DESTINATION).

### Źródło i cel

Oznacz jeden lister jako **SRC**, a drugi jako **DST** znaczkami w pasku ścieżki (ponowne kliknięcie zdejmuje rolę).
Potem:

| Akcja | Co robi |
|---|---|
| **Copy** (F5) | kopiuje zaznaczenie listera źródłowego do folderu listera docelowego |
| **Move** (F6) | przenosi je tam |
| **Extract** (⌘E) | rozpakowuje zaznaczone archiwa do nowego podfolderu folderu docelowego |
| **Compare** | zaznacza w obu listerach elementy, których brakuje po drugiej stronie albo które się różnią (rozmiar / nowsze) |
| **Swap** | zamienia role miejscami |
| **Open in Destination** | menu kontekstowe: pokazuje zaznaczony folder w liście docelowym |

Gdy żaden lister nie jest oznaczony jako SRC, źródłem jest ten, w którym wciśnięto przycisk.

**Postęp i Cancel.** Copy i Move pokazują w linii stanu pasek postępu (element, bajty, bieżący plik) z przyciskiem
**Cancel**; foldery są przetwarzane plik po pliku, więc anulowanie działa między plikami. Przeniesienie w obrębie
tego samego woluminu to zwykła zmiana nazwy.

**Konflikty** są rozstrzygane pojedynczo, z rozmiarem i datą starego i nowego elementu: **Replace** (stary trafia
do Kosza), **Replace If Newer**, **Keep Both** („nazwa 2.ext”), **Skip**, **Cancel**, a przy folderze na folder
także **Merge** (zawartość jest wtedy rozstrzygana element po elemencie). Zaznacz **Apply to all remaining
conflicts**, żeby nie być pytanym dalej.

**Lock Role** (menu na belce okna) przypina lister jako źródło albo cel: inny lister nie może przejąć roli, a jej
nie da się wyczyścić ani zamienić, dopóki nie odblokujesz.

### Klawiatura

| Klawisz | Akcja |
|---|---|
| Spacja | Quick Look (strzałki przechodzą po plikach, Spacja zamyka) |
| Return, ⌘↓ | otwórz plik / wejdź do folderu |
| Backspace, ⌘↑ | folder nadrzędny |
| ⌘⌫ | przenieś zaznaczenie do Kosza |
| F2 | zmień nazwę (przy kilku zaznaczonych: zmiana wielu nazw) |
| F5 / F6 | kopiuj / przenieś do listera docelowego |
| ⌘E | rozpakuj archiwa |
| ⌘I | informacje (rozmiar, daty, uprawnienia, właściciel) |
| ⌥⌘I | edycja atrybutów (uprawnienia, daty, ukryty, tagi, komentarz) |
| ⌘L | wpisz ścieżkę zamiast klikać breadcrumb |
| ⌘D | duplikuj zaznaczone pliki (`nazwa copy.ext`) |
| ⌥⌘D | **duplikuj ten lister** (ten sam folder, rozmiar, sortowanie, filtr) |
| ⌘F | filtr wzorcem |
| `+` / `-` / `*` | zaznacz wzorcem / odznacz wzorcem / odwróć zaznaczenie |
| ⌘A | zaznacz wszystko |
| ⌘B | dodaj bieżący folder do zakładek |
| ⌘⇧. | pokaż lub ukryj pliki ukryte |
| ⌘⇧L | wynieś wszystkie listery na wierzch |
| ⌘W | zamknij lister |

W wielu laptopach klawisze F wymagają **fn**.

### Menu

- **Prawy przycisk na liście plików** – polecenia dla elementów pod kursorem (Open, Quick Look, Extract,
  Copy/Move do celu, Rename, Info, Duplicate, Reveal in Finder, Copy Path, Move to Trash), a po kliknięciu pustego
  miejsca dla folderu (Select by Pattern, Filter, Calculate Folder Sizes, Compare, New Folder …).
- **Prawy przycisk na belce okna** (albo Control-klik) – polecenia listera: **Duplicate Lister**, New Lister,
  Set as Source / Destination, Swap, Parent, Back, Refresh, pliki ukryte, Filter, Bookmarks, Recent Folders,
  Terminal Here, Bring All to Front, Close, Close All, Save/Restore Layout.
- **Ikona w pasku menu** – lista wszystkich otwartych listerów (kliknięcie wynosi lister na wierzch; role widać jako
  \[SRC\] / \[DST\]), Bring All to Front, Close All, *Duplicate Frontmost Lister*, *Terminal App*, układy,
  *Edit Filetypes…*, *Edit Buttons…*, *Reload Buttons*, *Reset Buttons to Defaults*, stan uprawnień.

### Zaznaczanie, filtr, rozmiary

- **Zaznaczanie wzorcem** (`+`): wildcardy jak `*.jpg`, `IMG_??.png`; kilka wzorców oddzielonych spacjami;
  tekst bez wildcardów pasuje do nazw, które go zawierają. `-` odznacza, `*` odwraca.
- **Filter** (⌘F): pokazuje tylko pliki pasujące do wzorca (foldery zawsze zostają). Pusty wzorzec czyści filtr.
- **Select by Attributes** (menu kontekstowe na pustym miejscu albo przycisk): warunki na nazwę, rodzaj (obrazy,
  dźwięk, wideo, dokumenty, archiwa, foldery, pliki), rozmiar (większy / mniejszy niż) i datę modyfikacji (w ciągu
  ostatnich N dni / starsze niż N dni). Każdy ustawiony warunek musi być spełniony.
- **Sizes**: liczy rekurencyjny rozmiar zaznaczonych folderów (albo wszystkich) do kolumny Size.

### Zmiana nazw, atrybuty, dowiązania

- **Zmiana wielu nazw** (F2 przy kilku elementach albo *Rename N Items…*): znajdź i zamień (zwykły tekst albo
  wyrażenie regularne z `$1`, `$2`, opcjonalnie z wielkością liter), szablon nazwy z `[N]` nazwa, `[C]` licznik
  (start i liczba cyfr), `[D]` data modyfikacji i `[E]` rozszerzenie, małe / DUŻE litery / Wielkie Początki i nowe
  rozszerzenie. Podgląd pokazuje każdą parę stara → nowa nazwa, a puste nazwy, duplikaty i kolizje z istniejącymi
  plikami zaznacza na czerwono. Zmiana idzie przez nazwy tymczasowe, więc można zamieniać nazwy miejscami.
- **Atrybuty** (⌥⌘I, menu kontekstowe): uprawnienia jako siatka odczyt/zapis/wykonanie (opcjonalnie dla całej
  zawartości folderów, które zostają przeszukiwalne), daty modyfikacji i utworzenia, flaga ukrycia, tagi Findera
  i komentarz. Zmieniane są tylko włączone grupy.
- **Make Alias** i **Make Symbolic Link** (menu kontekstowe): tworzone obok oryginałów albo w folderze listera
  docelowego, jeśli jest.
- **Open With** (menu kontekstowe na plikach): aplikacje, które mogą otworzyć plik, domyślna pierwsza, albo *Other…*.

### Zakładki i historia

Menu **Go** zawiera *miejsca* (Home, Desktop, Documents, Downloads, Applications, Root, zamontowane woluminy),
*zakładki* (dodaj bieżący folder, usuń) i *ostatnie* foldery. Zakładki są w pliku `bookmarks.json`.

### Filetypes: co robi dwuklik

`filetypes.json` (ikona w pasku menu → **Edit Filetypes…**) przypisuje akcje do rozszerzeń: `open` (domyślne
zachowanie systemu), `extract`, `quicklook`, `app` (identyfikator lub ścieżka aplikacji) i `shell` (plik jest
w `$LISTER_SELECTION`). Domyślnie archiwa są **rozpakowywane**, a nie otwierane. Przykład:

```json
[
  { "extensions": ["zip", "tar.gz", "7z", "rar"], "action": "extract" },
  { "extensions": ["md", "txt"], "action": "app", "app": "com.apple.TextEdit" },
  { "extensions": ["png", "jpg"], "action": "quicklook" }
]
```

Plik zastępuje reguły domyślne, a zmiany są wczytywane od razu.

### Układy

Ikona w pasku menu → **Save Layout** zapamiętuje każdy otwarty lister (folder, pozycję, rozmiar, rolę,
sortowanie, pliki ukryte, filtr); **Restore Layout** otwiera je z powrotem. Automatyczne przywracanie przy starcie:

```bash
defaults write com.example.MacLister restoreLayoutAtLaunch -bool true
```

## Serwery: FTP, FTPS i SFTP

Lister może pokazywać serwer jak folder. **Go → Connect to Server…** (albo ⌘K, albo ikona w pasku menu) pyta
o protokół, adres, port, użytkownika i hasło. SFTP może używać pliku klucza (i jego hasła) albo Twojego ssh-agenta.
**Remember this server** wstawia serwer do menu Go, a **Save the password in the Keychain** trzyma hasło w Pęku kluczy,
a nie w żadnym pliku.

| Protokół | Uwagi |
|---|---|
| **SFTP** (SSH) | systemowy `sftp` z OpenSSH i jedno połączenie w tle na serwer, więc logowanie dotyczy tylko pierwszej operacji |
| **FTPS explicit** (`AUTH TLS`, port 21) | systemowy `curl`; certyfikat jest sprawdzany |
| **FTPS implicit** (port 990) | to samo, TLS od pierwszego bajtu |
| **FTP** | bez szyfrowania: MacLister ostrzega, że hasło idzie jawnym tekstem |

- **Klucze serwera (SFTP):** przy pierwszym połączeniu dostajesz odciski i decydujesz, czy zaufać; są trzymane
  we własnym `known_hosts` MacLister. Jeśli klucz zaufanego serwera się zmieni, połączenie jest odrzucane.
- **Certyfikaty (FTPS):** niezaufany certyfikat jest odrzucany, chyba że zaznaczysz *Accept an untrusted certificate*
  (z ostrzeżeniem).
- **Hasła** trafiają do `curl` przez konfigurację na stdin, a do `ssh` przez `SSH_ASKPASS`; nigdy do linii poleceń.

Co działa na serwerze: przeglądanie (breadcrumb, kolumny, sortowanie, filtr, pliki ukryte, zakładki, historia,
wpisanie ścieżki albo pełnego URL), otwieranie pliku (najpierw pobiera się do cache), Quick Look, **Copy i Move między
listerem serwera a lokalnym w obu kierunkach** (listery źródłowy i docelowy, przeciąganie na serwer), Move wewnątrz
jednego serwera, **New Folder, Rename, Delete** (serwery nie mają Kosza, więc usuwanie pyta najpierw). Transfery mają
ten sam pasek postępu, Cancel i pytania o konflikty (Replace, Replace If Newer, Keep Both, Skip, Merge) co lokalne.

**Znaki wieloznaczne w nazwach SFTP:** `sftp` z OpenSSH rozwija `* ? [ ] { }` w nazwach plików i nie ma jak tego
wyłączyć, więc plik `star*.txt` mógłby dopasować też `starfish.txt`. MacLister najpierw sprawdza listę folderu:
pobranie albo listowanie, które byłoby niejednoznaczne, jest odrzucane z wyjaśnieniem, usuwanie idzie przez tymczasową
zwykłą nazwę (żeby nic innego nie ucierpiało), a nazwy z `{` lub `}` są odrzucane. Wysyłanie plików lokalnych
z takimi nazwami idzie przez tymczasowe dowiązanie.

Jeszcze nie na serwerach: atrybuty i Info, aliasy, rozpakowywanie archiwów, liczenie rozmiarów folderów, zmiana wielu
nazw, przeciąganie plików *z* listera serwera, kopiowanie między dwoma serwerami albo wewnątrz jednego, wznawianie
przerwanych transferów, automatyczne odświeżanie. Ścieżki FTP są względne do folderu logowania. Dowiązania symboliczne
na serwerze są pokazywane jako pliki; dwuklik najpierw próbuje do nich wejść. Otwarcie pliku z serwera pobiera go,
zmiany nie są odsyłane z powrotem.

## Skróty klawiszowe, które możesz ustawić

Ikona w pasku menu → **Keyboard Shortcuts…** (także w menu na belce okna). Kliknij skrót i naciśnij klawisze; Esc
anuluje, Delete usuwa.

- **W każdej aplikacji:** *Open a lister* (przy wskaźniku myszy) i *Bring all listers to the front*.
- **W listerach:** osobny skrót dla każdej akcji (Copy, Move, Extract, Compare, Connect to Server, Lock Role, Select by
  Pattern …), oprócz wbudowanych klawiszy.

Każdy skrót jest sprawdzany przed przyjęciem, a okno tłumaczy, co jest nie tak:

1. wymaga ⌘, ⌥ lub ⌃ (klawisze funkcyjne i strzałki mogą stać samotnie w listerach; skróty globalne zawsze wymagają
   modyfikatora);
2. nie może być skrótem macOS: MacLister czyta włączone skróty z Ustawienia systemowe → Klawiatura → Skróty (Spotlight,
   Mission Control, zrzuty ekranu, przełączanie pulpitów …) razem z Twoimi zmianami;
3. nie może być klawiszem, który należy do każdej aplikacji (⌘Q, ⌘W, ⌘M, ⌘H, ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z, ⌘Tab) ani takim,
   którego MacLister już używa;
4. skrót globalny nie może być zajęty przez inną aplikację (pytany jest system);
5. kombinacja przypisana do innej akcji pyta, czy ją przenieść.

Przypisania są w `shortcuts.json`.

## Postęp w pasku menu

Gdy cokolwiek się kopiuje, przenosi, pobiera lub usuwa, ikona w pasku menu zamienia się w pierścień postępu z procentem
(kilka zadań: ich średnia), a podpowiedź mówi, co trwa.

## Konfiguracja

Pliki w `~/Library/Application Support/MacLister/`:

| Plik | Do czego |
|---|---|
| `buttons.json` | dolny pasek przycisków |
| `filetypes.json` | akcje dwukliku |
| `bookmarks.json` | zakładki |
| `layout.json` | zapisany układ |
| `shortcuts.json` | Twoje skróty klawiszowe |
| `servers.json` | zapisane serwery (bez haseł; te są w Pęku kluczy) |
| `known_hosts` | zaufane klucze serwerów SFTP |

### Przyciski

Ikona w pasku menu → **Edit Buttons…**, potem **Reload Buttons** (odświeża wszystkie otwarte listery). **Reset
Buttons to Defaults** nadpisuje plik ustawieniami domyślnymi (użyj po aktualizacji, żeby dostać nowe przyciski;
działa też `MacLister --reset-buttons`). Domyślny zestaw jest krótki: New Folder, Terminal Here, Copy, Move,
Extract, Compare, Info, Delete. Resztę (zaznaczanie, filtr, rozmiary, duplikowanie listera, swap …) masz w menu
i skrótach albo dodajesz jako przycisk.

```json
[
  { "title": "New Folder", "symbol": "folder.badge.plus", "action": "newFolder" },
  { "title": "Copy", "symbol": "doc.on.doc", "action": "copy", "help": "Kopiuj do celu (F5)" },
  { "title": "Code", "symbol": "chevron.left.forwardslash.chevron.right",
    "action": "shell", "command": "open -a 'Visual Studio Code' \"$LISTER_DIR\"" }
]
```

`symbol` to nazwa z SF Symbols (opcjonalnie), `color` barwi ikonę (`blue green orange red purple teal pink yellow
brown gray`; domyślnie neutralna), `help` to podpowiedź, `requiresSelection` (true/false) nadpisuje to, kiedy
przycisk jest aktywny. `{ "title": "", "action": "separator" }` rysuje cienką kreskę między grupami. **Akcje:** `newFolder terminalHere delete parent back refresh revealInFinder open
newLister toggleHidden copy move setSource setDestination swapSourceDestination extract bringAllToFront
duplicateLister duplicateFile selectPattern deselectPattern selectAll selectNone invertSelection filter
clearFilter calcSizes compare info showInDestination destinationHere addBookmark makeAlias makeSymlink selectByAttributes toggleRoleLock batchRename attributes separator shell`.
`shell` uruchamia `command` w `/bin/zsh` w bieżącym folderze; `$LISTER_DIR` to ten folder, a `$LISTER_SELECTION`
to zaznaczone ścieżki, po jednej w wierszu.

### Ustawienia ukryte

Ustawiane przez `defaults write com.example.MacLister <klucz> <wartość>`:

| Klucz | Domyślnie | Znaczenie |
|---|---|---|
| `centerOnCursor` | false | wyśrodkuj nowe listery na kliknięciu zamiast kotwiczyć róg |
| `showStatusItem` | true | pokaż ikonę w pasku menu (po ukryciu zamykasz aplikację z Monitora aktywności) |
| `startDirectory` | `~` | folder otwierany dwuklikiem na pulpicie |
| `terminalBundleID` | `com.apple.Terminal` | terminal dla *Terminal Here* (także: ikona w pasku menu → *Terminal App*) |
| `restoreLayoutAtLaunch` | false | otwórz zapisany układ przy starcie |
| `desktopTrigger` | `doubleClick` | `doubleClick`, `middleClick` albo `both` (także: ikona w pasku menu → *Open Lister With*) |
| `buttonBarPosition` | `abovePath` | `abovePath`, `belowPath` albo `bottom` |
| `showButtonLabels` | false | napisy obok ikon przycisków |
| `debugHitTest` | false | zapisuj decyzję dla każdego kliknięcia do `~/Library/Logs/MacLister.log` |

## Rozwiązywanie problemów

- **Dwuklik nic nie robi.** Otwórz menu pod ikoną: jeśli widzisz *Waiting for Accessibility permission…*, nadaj oba
  uprawnienia (krok 4) i uruchom aplikację ponownie. Jeśli uprawnienia wyglądają dobrze, ale są ignorowane
  (np. po ponownej instalacji), zresetuj je i nadaj od nowa:

  ```bash
  tccutil reset All com.example.MacLister
  ```

- **Lister otwiera się na ikonie albo nie otwiera się na pustym miejscu.** Włącz `debugHitTest` i zajrzyj do
  `~/Library/Logs/MacLister.log` – każdy dwuklik zapisuje, co było pod kursorem.
- **Okna odsuwają się, a lister jest w połowie poza ekranem.** Wyłącz *Kliknij tapetę, aby odsłonić pulpit*
  (krok 6 instalacji).
- **„Terminal Here” otwiera nie tę aplikację.** Ikona w pasku menu → *Terminal App*.
- **Po aktualizacji brakuje nowych przycisków.** Ikona w pasku menu → *Reset Buttons to Defaults*.
- **Gatekeeper pisze, że aplikacja jest uszkodzona albo nie można jej otworzyć.** Krok 3 instalacji
  (`xattr -dr com.apple.quarantine`).

## Budowanie ze źródeł

Wymaga Xcode albo Command Line Tools (Swift 5.9+).

```bash
./build.sh                       # build/MacLister.app dla tego Maca
./build.sh release --universal   # arm64 + x86_64
./package.sh                     # wersja uniwersalna spakowana do dist/ z sumą SHA-256
```

Wbudowane samotesty prowadzą prawdziwe listery przez role, kopiowanie/przenoszenie, rozpakowywanie, menu, filtry
i więcej, a wyniki PASS/FAIL zapisują w `~/Library/Logs/MacLister.log`:

```bash
open build/MacLister.app --args --selftest
open build/MacLister.app --args --selftest-features
```

Testy serwerów działają na małych lokalnych serwerach FTP/FTPS (Python ze standardowej biblioteki,
`Tools/mock_ftp_server.py`): uruchom go z `--port`, `--root` i opcjonalnie `--tls explicit|implicit --cert … --key …`,
a potem `open build/MacLister.app --args --selftest-remote ftp=2121 ftpes=2122 ftps=2123 root=<serwowany folder>`.

SFTP jest testowany na dwa sposoby: `sftpdir=<folder>` uruchamia polecenia `sftp` na systemowym lokalnym `sftp-server`
(bez sieci), a `sftp=<port> sshuser=… key=… pkey=… "pass=…" sshdir=…` na tymczasowym `sshd` uruchomionym na `127.0.0.1`
z własnymi kluczami (zaufanie do klucza serwera, pliki kluczy, hasła kluczy przez `SSH_ASKPASS`, zmienione klucze serwera).

`MacLister --open [folder]` otwiera lister przy starcie.

Ikona aplikacji jest rysowana kodem: `swift Tools/make_icon.swift` odtwarza `Support/AppIcon.icns` (dwa nakładające
się okna listerów, źródło niebieskie i cel pomarańczowy, z bramkami w stylu Amigi na zaokrąglonym kwadracie macOS).

Układ kodu: `Sources/MacLister/` – `DesktopDoubleClickMonitor` (nasłuch zdarzeń), `DesktopHitTest` (czy to puste
miejsce pulpitu?), `ListerWindowController` / `ListerManager` (okna, role), `ListerViewController` (+ `Features`)
(tabela plików i akcje), `Bars` (paski ścieżki i przycisków w SwiftUI), `FileTransfer`, `ArchiveExtractor`,
`Stores` (zakładki, historia, filetypes, układy).

## Prywatność i bezpieczeństwo

- Żeby wykryć dwuklik, MacLister czyta zdarzenia przycisków myszy w całym systemie przez **pasywny** nasłuch
  (listen-only): nie może zmieniać ani blokować Twoich danych wejściowych i ignoruje klawisze. macOS zalicza to
  do *Monitorowania wprowadzania*.
- Dostępność służy tylko do sprawdzenia, jaki element jest pod kursorem.
- Brak dostępu do sieci i telemetrii. Jedyny log to `~/Library/Logs/MacLister.log` (stan startu; kliknięcia tylko
  przy `debugHitTest`).
- Aplikacja **nie działa w sandboxie** (musi przeglądać dowolne foldery), jest podpisana ad-hoc i **bez notaryzacji**.
  Dlatego nie można jej dystrybuować przez Mac App Store.
- Foldery takie jak Desktop, Documents i Downloads wywołują zwykłe pytania macOS o dostęp do plików.

## Znane ograniczenia

Serwery obsługują tylko przeglądanie, kopiowanie i podstawowe operacje na folderach (zob. *Serwery*).
Brak wyszukiwania plików, widoku drzewa i podglądu hex; archiwów nie da się przeglądać jak folderów (są
rozpakowywane). Przeciąganie stosuje reguły Findera, a otwieranie folderów po najechaniu nie jest zaimplementowane.
Archiwa z hasłem kończą się komunikatem o błędzie.
